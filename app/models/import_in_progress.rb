require 'nkf'
class ImportInProgress < ActiveRecord::Base
  belongs_to :user
  belongs_to :project

  before_save :encode_csv_data

  # Batch-import state persisted between run requests, stored as JSON in the
  # `settings` text column (mirrors Redmine core's Import#settings).
  def import_settings
    @import_settings ||= settings.blank? ? {} : JSON.parse(settings)
  end

  def import_settings=(hash)
    @import_settings = hash
    self.settings = JSON.generate(hash)
  end

  def save_import_settings!
    self.settings = JSON.generate(import_settings)
    save!
  end

  private
  def encode_csv_data
    return if self.csv_data.blank?
    return unless will_save_change_to_csv_data?

    self.csv_data = self.csv_data
    # 入力文字コード
    encode = case self.encoding
             when "U"
               "-W"
             when "EUC"
               "-E"
             when "S"
               "-S"
             when "N"
               ""
             else
               ""
             end

    self.csv_data = NKF.nkf("#{encode} -w", self.csv_data).encode('UTF-8', 'UTF-8', invalid: :replace, undef: :replace)
  end
end
