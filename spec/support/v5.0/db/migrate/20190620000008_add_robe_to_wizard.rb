# typed: false
class AddRobeToWizard < ActiveRecord::Migration[5.0]
  def change
    create_table :robe do |t|
      t.references :wizard
    end
  end
end
