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
      refute_includes payload, "250000.0"
    end

    def test_normalize_description_folds_vietnamese_diacritics_to_ascii
      assert_equal "Thanh toan hoa don", VietQR.normalize_description("Thanh toán hóa đơn")
      assert_equal "DON HANG HD1234", VietQR.normalize_description("ĐƠN HÀNG HD1234")
      assert_equal "Nguyen Van A u y", VietQR.normalize_description("Nguyễn Văn Ậ ự ỹ")
    end

    def test_normalize_description_truncates_and_leaves_no_trailing_space
      normalized = VietQR.normalize_description("thanh toan hoa don cho khach hang")

      assert_equal VietQR::MAX_DESCRIPTION, normalized.length
      assert_equal normalized, normalized.strip
      assert_equal "", VietQR.normalize_description(nil)
    end

    # The whole payload must stay ASCII: EMVCo lengths count bytes, and a bank scanner
    # that receives a multi-byte memo mangles or rejects it.
    def test_a_diacritic_memo_yields_an_ascii_payload_with_byte_exact_lengths
      memo    = "Thanh toán đơn HD1234"
      payload = VietQR.payload(bank_bin: "970423", account_number: "0123456789", description: memo)
      expected = VietQR.normalize_description(memo)

      assert_predicate payload, :ascii_only?
      assert_includes payload, "62#{format('%02d', expected.bytesize + 4)}08#{format('%02d', expected.bytesize)}#{expected}"
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

    def test_a_blank_or_non_alphanumeric_identifier_raises
      [nil, "", "0123 4567", "97/0423"].each do |bad|
        error = assert_raises(Error) { VietQR.payload(bank_bin: "970423", account_number: bad) }

        assert_equal "QR_INPUT", error.code
      end
    end
  end
end
