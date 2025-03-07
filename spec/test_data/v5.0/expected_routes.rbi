# typed: strong
# This is an autogenerated file for Rails routes.
# Please run rake rails_rbi:routes to regenerate.
class ActionController::Base
  include GeneratedUrlHelpers
end

module ActionView::Helpers
  include GeneratedUrlHelpers
end

module GeneratedUrlHelpers
  # Sigs for route /test/index(.:format)
  sig { params(args: T.untyped, kwargs: T.untyped).returns(String) }
  def test_index_path(*args, **kwargs); end

  sig { params(args: T.untyped, kwargs: T.untyped).returns(String) }
  def test_index_url(*args, **kwargs); end
end
