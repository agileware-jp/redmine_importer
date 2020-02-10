require 'nkf'
class ImportInProgress < ActiveRecord::Base
  unloadable
  belongs_to :user
  belongs_to :project

  before_save :encode_csv_data

  private
  def encode_csv_data
    return if self.csv_data.blank?

    self.csv_data = self.csv_data
    # 入力文字コード
    encode = case self.encoding
             when "UTF-8"
               "-W"
             when "EUC-JP"
               "-E"
             when "SJIS"
               "-S"
             when "N"
               ""
             else
               ""
             end

    self.csv_data = NKF.nkf("#{encode} -w", self.csv_data)
  end
end
