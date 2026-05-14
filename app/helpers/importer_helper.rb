module ImporterHelper
  def matched_attrs(column)
    matched = ''
    @attrs.each do |k,v|
      if v.to_s[/(?<=-).*/].casecmp(column.to_s.sub(" ") {|sp| "_" }) == 0 \
        || k.to_s.casecmp(column.to_s) == 0

        matched = v
      end
    end
    matched
  end

  def force_utf8(str)
    str.unpack("U*").pack('U*')
  end
end
