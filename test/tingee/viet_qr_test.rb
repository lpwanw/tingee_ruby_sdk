require "test_helper"

module Tingee
  class VietQRTest < Minitest::Test
    # Verbatim from openhoangnc/vietqr's libs/test-data.json — the port's oracle.
    # Several VietQR write-ups publish a CRC variant that appends two zero bytes; if a
    # change makes these fail, the fixtures are right and the change is wrong.
    # [bank_bin, account_number, amount, description, expected]
    FIXTURES = [
      ["970423", "0123456789", 0, "",
       "00020101021138540010A00000072701240006970423011001234567890208QRIBFTTA53037045802VN6304F64B"],
      ["963388", "3456789143", 0, "",
       "00020101021138540010A00000072701240006963388011034567891430208QRIBFTTA53037045802VN63041D58"],
      ["963388", "3456789143", 2_345_123, "",
       "00020101021138540010A00000072701240006963388011034567891430208QRIBFTTA5303704540723451235802VN6304EBDA"],
      ["963388", "3456789143", 2_345_123, "thanh toan hoa don",
       "00020101021138540010A00000072701240006963388011034567891430208QRIBFTTA5303704540723451235802VN62220818thanh toan hoa don630445F2"]
    ].freeze

    def test_reproduces_every_upstream_fixture_byte_exact
      FIXTURES.each do |bin, account, amount, description, expected|
        actual = VietQR.payload(bank_bin: bin, account_number: account, amount:, description:)

        assert_equal expected, actual, "fixture #{bin}/#{account} amount=#{amount} desc=#{description.inspect}"
      end
    end

    # 0 is falsy in the JS original but truthy in Ruby — porting `if (amount)` literally
    # would emit a bogus empty field 54 and a QR the bank app rejects.
    def test_a_zero_or_nil_amount_omits_the_amount_field
      open_amount = VietQR.payload(bank_bin: "970423", account_number: "0123456789")

      # currency (5303704) butting straight against country (5802VN) = no field 54 between
      assert_includes open_amount, "53037045802VN"
      assert_equal open_amount, VietQR.payload(bank_bin: "970423", account_number: "0123456789", amount: 0)
    end

    # A Float total would serialize as "250000.0" and corrupt both the field and its length.
    def test_a_float_amount_emits_integer_dong
      payload = VietQR.payload(bank_bin: "970423", account_number: "0123456789", amount: 250_000.0)

      assert_includes payload, "5406250000"
    end

    def test_normalize_description_folds_vietnamese_diacritics_to_ascii
      assert_equal "Thanh toan hoa don", VietQR.normalize_description("Thanh toán hóa đơn")
      assert_equal "DON HANG HD1234", VietQR.normalize_description("ĐƠN HÀNG HD1234")
      assert_equal "Nguyen Van A u y", VietQR.normalize_description("Nguyễn Văn Ậ ự ỹ")
    end

    def test_normalize_description_truncates_to_the_emvco_cap
      # literal 25, not MAX_DESCRIPTION: comparing the constant to itself holds for any value
      assert_equal 25, VietQR::MAX_DESCRIPTION
      assert_equal "thanh toan hoa don cho kh", VietQR.normalize_description("thanh toan hoa don cho khach hang")
    end

    # Char 25 of this input IS a space, so the post-truncation strip is load-bearing;
    # the obvious inputs cut mid-word and let a missing strip pass unnoticed.
    def test_normalize_description_leaves_no_trailing_space_after_truncation
      normalized = VietQR.normalize_description("thanh toan hoa don cho k hang")

      assert_equal "thanh toan hoa don cho k", normalized
      refute normalized.end_with?(" ")
    end

    def test_normalize_description_of_nil_or_blank_is_empty
      assert_equal "", VietQR.normalize_description(nil)
      assert_equal "", VietQR.normalize_description("   ")
    end

    # The whole payload must stay ASCII: EMVCo lengths count bytes, and a bank scanner
    # that receives a multi-byte memo mangles or rejects it.
    def test_a_diacritic_memo_yields_an_ascii_payload
      payload = VietQR.payload(bank_bin: "970423", account_number: "0123456789",
                               description: "Thanh toán đơn HD1234")

      assert_predicate payload, :ascii_only?
      assert_includes payload, "62250821Thanh toan don HD1234"
    end

    # EMVCo lengths count BYTES; the JS original used UTF-16 units. Asserted on the
    # helper directly, since a normalized description is always ASCII downstream and
    # bytesize == length there, which makes the distinction invisible through #payload.
    def test_tlv_lengths_count_bytes_not_characters
      assert_equal "0806Thánh", VietQR.tlv("08", "Thánh") # 5 characters, 6 bytes
    end

    # Without this guard format("%02d", 100) emits a 3-digit length and corrupts the payload.
    def test_a_value_too_long_for_a_two_digit_length_raises
      error = assert_raises(Error) { VietQR.payload(bank_bin: "970423", account_number: "1" * 90) }

      assert_equal "QR_INPUT", error.code
    end

    def test_an_empty_description_omits_the_purpose_field
      payload = VietQR.payload(bank_bin: "970423", account_number: "0123456789", description: "   ")

      # identical to the no-description payload = field 62 omitted, not emitted empty
      assert_equal VietQR.payload(bank_bin: "970423", account_number: "0123456789"), payload
    end

    # to_s(16) instead of format("%04X") silently drops the leading zero and shortens
    # the payload by a byte; 0000000004 is a known leading-zero case.
    def test_the_crc_is_four_uppercase_hex_chars_including_a_leading_zero
      assert_equal "07AD", VietQR.payload(bank_bin: "970423", account_number: "0000000004")[-4..]

      FIXTURES.each do |bin, account, amount, description, _|
        crc = VietQR.payload(bank_bin: bin, account_number: account, amount:, description:)[-4..]

        assert_match(/\A[0-9A-F]{4}\z/, crc)
      end
    end

    # "1.234.567" is the ordinary Vietnamese money format and arrives from form fields,
    # CSVs and number_with_delimiter round-trips. String#to_i would coerce it to 1, and
    # the payer would scan a QR reading 1 dong, pay it, and nobody would notice.
    def test_a_formatted_or_fractional_amount_raises_rather_than_coercing
      ["250.000", "1.234.567", "250,000", "abc", "", 250_000.5, -50_000, Float::INFINITY].each do |bad|
        error = assert_raises(Error, "expected #{bad.inspect} to be rejected") do
          VietQR.payload(bank_bin: "970423", account_number: "0123456789", amount: bad)
        end

        assert_equal "QR_INPUT", error.code
      end
    end

    def test_whole_amounts_are_accepted_in_the_shapes_a_rails_app_produces
      [250_000, 250_000.0, "250000", Rational(250_000, 1)].each do |good|
        payload = VietQR.payload(bank_bin: "970423", account_number: "0123456789", amount: good)

        assert_includes payload, "5406250000", "#{good.inspect} should emit 250000 dong"
      end
    end

    # A Latin-1 paste or a byte-truncated memo must not escape as a raw ArgumentError
    # from unicode_normalize, past a caller's rescue Tingee::Error.
    def test_an_invalid_utf8_memo_is_scrubbed_rather_than_raising
      assert_equal "caf HD1", VietQR.normalize_description("caf\xE9 HD1")
      assert_equal "x", VietQR.normalize_description("x".b + "\xE9".b)
    end

    # NFKD (not NFD) folds fullwidth forms; non-ASCII becomes a space so an en dash or
    # NBSP cannot fuse two words together.
    def test_normalize_description_folds_fullwidth_and_does_not_fuse_words
      assert_equal "Thanh toan HD1234", VietQR.normalize_description("Thanh toán ＨＤ１２３４")
      assert_equal "Thanh toan HD1", VietQR.normalize_description("Thanh toán – HD1")
      assert_equal "HD1 234", VietQR.normalize_description("HD1\u00A0234")
    end

    # A memo that survives normalization as nothing yields a QR with no reference at
    # all, which the auto-confirm matcher can never key on.
    def test_a_memo_that_normalizes_to_empty_raises
      error = assert_raises(Error) { VietQR.normalize_description("☃☃") }

      assert_equal "QR_INPUT", error.code
    end

    def test_a_blank_or_non_alphanumeric_identifier_raises
      [nil, "", "0123 4567", "97/0423"].each do |bad|
        error = assert_raises(Error) { VietQR.payload(bank_bin: "970423", account_number: bad) }

        assert_equal "QR_INPUT", error.code
      end
    end
  end
end
