module Tingee
  # A non-"00" Tingee response, or a transport/config failure. `code` keeps Tingee's
  # raw code for programmatic handling. Two undocumented-but-observed series exist and
  # are NOT reconciled by Tingee: business codes 1001–1076, and signature codes
  # 90 (bad timestamp) / 91 (timeout) / 97 (bad signature). We keep the raw code as-is.
  class Error < StandardError
    attr_reader :code

    def initialize(code, detail)
      @code = code
      super("Tingee error #{code}: #{detail}")
    end
  end
end
