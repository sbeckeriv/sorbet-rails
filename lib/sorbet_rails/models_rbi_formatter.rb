# typed: true
class ModelsRbiFormatter
  extend T::Sig

  RUBY_TO_SORBET_TYPE_MAPPING = {
    boolean: 'T::Boolean',
    date: 'Date',
    datetime: 'DateTime',
    decimal: 'Integer',
    integer: 'Integer',
    string: 'String',
    text: 'String',
    json: 'Hash',
    jsonb: 'Hash',
  }

  sig{params(model_classes: T::Array[T.class_of(ActiveRecord::Base)]).void}
  def initialize(model_classes)
    @model_classes = model_classes
    @buffer = []
  end

  sig{returns(String)}
  def generate_rbi
    @model_classes.each do |model_class|
      # TODO write a standalone class that generate rbi for a single model
      begin
        formatter = ModelFormatter.new(model_class)
        @buffer << "\n"
        @buffer << formatter.generate_rbi
      rescue StandardError => ex
        puts "---"
        puts "Error when handling mode #{@model_class.name}: #{ex}"
      end
    end
    result
  end

  sig{returns(String)}
  def result
    <<~MESSAGE
      # This is an autogenerated file for dynamic methods in ActiveRecord models
      # typed: true
      #{@buffer.join("\n")}
    MESSAGE
  end

  class ModelFormatter
    extend T::Sig

    sig{params(model_class: T.class_of(ActiveRecord::Base)).void}
    def initialize(model_class)
      @model_class = model_class
      @columns_hash = model_class.columns_hash
      @generated_sigs = ActiveSupport::HashWithIndifferentAccess.new
    end

    def generate_rbi
      populate_generated_column_methods
      populate_generated_association_methods

      @buffer = []
      @buffer << draw_class_header

      @model_class.new.methods.sort.each do |method_name|
        next unless is_method_autogenerated?(method_name)

        expected_sig = @generated_sigs[method_name]
        next unless expected_sig.present?
        next unless matched_signature?(method_name, expected_sig)
        @buffer << generate_method_sig(method_name, expected_sig).indent(2)
      end

      @buffer << draw_class_footer
      @buffer.join("\n")
    end

    def populate_generated_column_methods
      @columns_hash.each do |column_name, column_def|
        column_type = type_for_column_def(column_def)

        @generated_sigs.merge!({
          "#{column_name}" => { ret: column_type },
          "#{column_name}=" => {
            args: [ name: :value, arg_type: :req, value_type: column_type ],
          },
        })

        if column_def.type == :boolean
          @generated_sigs["#{column_name}?"] = {
            ret: "T::Boolean",
            args: [ name: :args, arg_type: :rest, value_type: 'T.untyped' ],
          }
        end
      end
    end

    def populate_generated_association_methods
      @model_class.reflections.each do |assoc_name, reflection|
        reflection.collection? ?
          populate_collection_assoc_getter_setter(assoc_name, reflection) :
          populate_single_assoc_getter_setter(assoc_name, reflection)
      end
    end

    def populate_single_assoc_getter_setter(assoc_name, reflection)
      # TODO allow people to specify the possible values of polymorphic associations
      assoc_class = polymorphic_assoc?(reflection) ? 'T.untyped' : reflection.class_name
      assoc_type = "T.nilable(#{assoc_class})"
      if reflection.belongs_to?
        # if this is a belongs_to connection, we may be able to detect whether
        # this field is required & use a stronger type
        column_def = @columns_hash[reflection.foreign_key.to_s]
        if column_def
          assoc_type = assoc_class if !column_def.null
        end
      end

      @generated_sigs.merge!({
        "#{assoc_name}" => { ret: assoc_type },
        "#{assoc_name}=" => {
          args: [ name: :value, arg_type: :req, value_type: assoc_type ],
        },
      })
    end

    def populate_collection_assoc_getter_setter(assoc_name, reflection)
      # TODO allow people to specify the possible values of polymorphic associations
      assoc_class = polymorphic_assoc?(reflection) ? 'T.untyped' : reflection.class_name
      @generated_sigs.merge!({
        "#{assoc_name}" => { ret: "ActiveRecord::Relation" },
        "#{assoc_name}=" => {
          args: [ name: :value, arg_type: :req, value_type: "T.any(T::Array[#{assoc_class}], ActiveRecord::Relation)" ],
        },
      })
    end

    def polymorphic_assoc?(reflection)
      reflection.through_reflection? ?
        polymorphic_assoc?(reflection.source_reflection) :
        reflection.polymorphic?
    end

    sig{returns(String)}
    def draw_class_header
      "class #{@model_class.name} < #{@model_class.superclass}"
    end

    sig{returns(String)}
    def draw_class_footer
      "end"
    end

    sig{params(buffer: T::Array[String]).void}
    def generate_column_methods(buffer)
      @columns_hash.each do |column_name, column_def|
        buffer << draw_column_methods(column_name, column_def)
      end
    end

    def type_for_column_def(column_def)
      strict_type = RUBY_TO_SORBET_TYPE_MAPPING[column_def.type] || 'T.untyped'
      column_def.null ? "T.nilable(#{strict_type})" : strict_type
    end

    def is_method_autogenerated?(method_name)
      # check if this method is autogenerated or overridden
      # Note: sometimes this is a module, sometimes it's an instance of a class
      owner_name = @model_class.instance_method(method_name).owner.to_s
      [
        "ActiveRecord::AttributeMethods::GeneratedAttributeMethods",
        "#{@model_class.name}::GeneratedAssociationMethods",
      ].any? { |k| owner_name.include?(k) }
    end

    def matched_signature?(method_name, generated_method_def)
      # use parameters reflection to find method arguments
      actual_params = @model_class.instance_method(method_name).parameters
      expected_args = generated_method_def[:args] || []
      expected_params = expected_args.map { |arg| [arg[:arg_type], arg[:name]] }
      actual_params == expected_params
    end

    def generate_method_sig(method_name, generated_method_def)
      # generated_method_def:
      # {
      # .  ret: <return_type>
      #    args: [ name: :value, arg_type: :req, value_type: "T.any(T::Array[#{assoc_class}], ActiveRecord::Relation" ]
      #  }
      #
      # Generate something like this
      #
      #  sig{returns(T.nilable(String))}
      # .def email; end
      #  sig{params(record: T.nilable(String)).void}
      #  def email=(record); end

      param_sig = ""
      param_def = ""
      if generated_method_def[:args]
        sig_args_string = generated_method_def[:args].map { |arg_def|
          "#{arg_def[:name]}: #{arg_def[:value_type]}"
        }.join(", ")
        param_sig = "params(#{sig_args_string})."

        param_def = generated_method_def[:args].map { |arg_def|
          prefix = ""
          prefix = "*" if arg_def[:arg_type] == :rest
          prefix = "**" if arg_def[:arg_type] == :keyrest

          "#{prefix}#{arg_def[:name]}"
        }.join(", ")
      end

      return_type = generated_method_def[:ret] ?
        "returns(#{generated_method_def[:ret]})" :
        "void"

      <<~MESSAGE
        sig{#{param_sig}#{return_type}}
        def #{method_name}(#{param_def}); end
      MESSAGE
    end
  end
end
