module Tingee
  # VietQR payment payloads, built locally — no img.vietqr.io round-trip and no Tingee
  # endpoint (theirs 500s, see docs/tingee-api-reference.md §10). A plain transfer into
  # the linked real account fires the payment webhook whatever minted the QR, so the
  # payer-facing code is purely a client-side string.
  #
  # Ported from https://github.com/openhoangnc/vietqr (MIT); test/tingee/viet_qr_test.rb
  # reproduces that project's fixtures byte-exact.
  #
  # Returns the EMVCo payload STRING, not an image. QR pixel encoding is Reed-Solomon +
  # masking, which would mean a runtime dependency and this gem has none — render the
  # string app-side with rqrcode (Ruby) or any JS QR library.
  module VietQR
    # EMVCo tag 62-08 (purpose of transaction) caps at 25 characters.
    MAX_DESCRIPTION = 25

    NAPAS_AID    = "A000000727".freeze # merchant account information: Napas
    SERVICE_CODE = "QRIBFTTA".freeze   # interbank funds transfer TO AN ACCOUNT
    CURRENCY_VND = "704".freeze        # ISO 4217
    COUNTRY_VN   = "VN".freeze

    module_function

    # bank_bin: the Napas BIN (`client.get_banks` → "bin", same value create_va takes).
    # account_number: the REAL account from confirm_va — where the money lands.
    # amount: integer VND; nil or 0 mints an open-amount QR the payer fills in.
    # description: the transfer memo; normalized (see #normalize_description).
    def payload(bank_bin:, account_number:, amount: nil, description: nil)
      beneficiary = tlv("00", validate_id!(bank_bin, "bank_bin")) +
                    tlv("01", validate_id!(account_number, "account_number"))
      merchant    = tlv("00", NAPAS_AID) + tlv("01", beneficiary) + tlv("02", SERVICE_CODE)
      memo        = normalize_description(description)
      dong        = validate_amount!(amount)

      s  = "000201"          # payload format indicator
      s += "010211"          # point of initiation: 11 = static/reusable (12 = single-use)
      s += tlv("38", merchant)
      s += tlv("53", CURRENCY_VND)
      # `if amount` alone would be a porting bug: 0 is falsy in the JS original but
      # truthy in Ruby, which would emit a bogus zero-amount field 54.
      s += tlv("54", dong.to_s) if dong.positive?
      s += tlv("58", COUNTRY_VN)
      s += tlv("62", tlv("08", memo)) unless memo.empty?
      s += "6304"            # CRC tag + length, both covered by their own checksum
      s + crc16(s)
    end

    # ASCII-folds Vietnamese diacritics and truncates to MAX_DESCRIPTION, because many
    # bank scanners mangle or reject a non-ASCII memo.
    #
    # PERSIST WHAT THIS RETURNS. "Thanh toán" becomes "Thanh toan", so a webhook matcher
    # grepping your original un-normalized string silently misses every payment.
    def normalize_description(str)
      normalized =
        str.to_s
           # A Latin-1 paste or a byte-truncated memo would otherwise raise a raw
           # ArgumentError out of unicode_normalize, past any rescue Tingee::Error.
           .encode("UTF-8", invalid: :replace, undef: :replace, replace: "")
           .unicode_normalize(:nfkd) # NFKD, not NFD: also folds fullwidth ＨＤ１ to HD1
           .gsub(/\p{Mn}/, "")       # drop combining diacritics: "toán" -> "toan"
           .tr("đĐ", "dD")           # not decomposable, needs its own mapping
           # Anything still non-ASCII becomes a space rather than vanishing, so an
           # en dash or NBSP cannot silently fuse two words into one.
           .gsub(/[^\x20-\x7E]/, " ")
           .squeeze(" ")
           .strip[0, MAX_DESCRIPTION]
           .strip                    # truncation can leave a trailing space mid-word

      # An unreferenced QR is unmatchable by construction (the auto-confirm matcher
      # keys on this memo), so refuse to turn a memo the caller meant into nothing.
      if normalized.empty? && !str.to_s.strip.empty?
        raise Error.new("QR_INPUT", "description #{str.inspect} normalized to empty; a QR with no memo cannot be matched")
      end

      normalized
    end

    # VND has no minor unit, so an amount must be a whole non-negative number of dong.
    # Deliberately NOT String#to_i, which coerces instead of parsing: "1.234.567" is
    # the ordinary Vietnamese money format and to_i turns it into a 1-dong QR that the
    # payer scans, pays, and nobody notices. nil (or 0) means an open-amount QR.
    def validate_amount!(amount)
      return 0 if amount.nil?

      dong = case amount
             when Numeric then (amount % 1).zero? ? amount.to_i : nil # Float/BigDecimal/Rational
             when String  then amount.match?(/\A\d+\z/) ? amount.to_i : nil
             end
      raise Error.new("QR_INPUT", "amount must be a whole non-negative number of dong, got #{amount.inspect}") if dong.nil? || dong.negative?

      dong
    end

    # EMVCo TLV: 2-char id + 2-char length + value. The length counts BYTES — the JS
    # original used String#length (UTF-16 units), which diverges on any non-ASCII value.
    def tlv(id, value)
      size = value.bytesize
      raise Error.new("QR_INPUT", "#{id} value is #{size} bytes; EMVCo length field holds 2 digits") if size > 99

      "#{id}#{format('%02d', size)}#{value}"
    end

    # CRC16-CCITT-FALSE: init 0xFFFF, poly 0x1021, no reflection, no final XOR.
    # Masked once at the end rather than each round — Ruby Integers are unbounded, so
    # the intermediate width differs from JS's 32-bit bitwise ops, the low 16 bits do not.
    def crc16(str)
      crc = 0xFFFF
      str.each_byte do |byte|
        crc ^= byte << 8
        8.times { crc = (crc & 0x8000).zero? ? crc << 1 : (crc << 1) ^ 0x1021 }
      end
      format("%04X", crc & 0xFFFF)
    end

    # Bank BIN and account number must survive a QR scan into a bank app's transfer
    # form, so reject anything but ASCII alphanumerics. No BIN whitelist here —
    # client.get_banks is the source of truth for what Tingee actually supports.
    def validate_id!(value, name)
      value = value.to_s
      raise Error.new("QR_INPUT", "#{name} must be non-empty ASCII alphanumerics, got #{value.inspect}") unless value.match?(/\A[A-Za-z0-9]+\z/)

      value
    end
  end
end
