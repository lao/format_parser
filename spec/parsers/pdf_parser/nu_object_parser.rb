class NuObjectParser
  Malformed = Class.new(RuntimeError)
  RE = ->(str) { /#{Regexp.escape(str)}/ }

  NAME_RE = begin
    # The ASCII subset permissible for PDF name values
    printable_ascii = (32..126).to_a
    printable_ascii.delete(' '.ord)
    printable_ascii.delete('['.ord)
    printable_ascii.delete(']'.ord)
    printable_ascii.delete('<'.ord)
    printable_ascii.delete('>'.ord)
    printable_ascii.delete('('.ord)
    printable_ascii.delete(')'.ord)
    printable_ascii.delete('/'.ord)
    printable_ascii.delete('\\'.ord)
    exact_char_class = printable_ascii.map(&:chr).join

    /\/[#{exact_char_class}]{0,}/
  end

  STRATEGIES = {
    RE['<<'] => :parse_dictionary,
    RE['[']  => :parse_array,
    RE['(']  => :parse_string,
    RE['<']  => :parse_hex_string,
    /\d+ \d+ R/ => :parse_ref,
    NAME_RE => :parse_pdf_name,

    RE['true']  => :wrap,
    RE['false'] => :wrap,
    RE['null']  => :wrap,

    # 34.5 −3.62 +123.6 4. −.002 0.0 are all valid reals
    /(\-|\+?)(\d+)\.(\d+)/ => :wrap_real,
    /(\-|\+?)(\d+)\./ => :wrap_real,
    /(\-|\+?)\.(\d+)/ => :wrap_real,
    /\-?(\d+)/ => :wrap_int,

    RE['obj']       => :wrap,
    RE['endobj']    => :wrap,
    RE['stream']    => :wrap,
    RE['endstream'] => :wrap,

    /\s+/           => :wrap_whitespace,
    /./             => :garbage,
  }

  # Permitted character escapes. There aren't _that_ many so we can use a table
  STRING_ESCAPES = {
    "\r"   => "\n",
    "\n\r" => "\n",
    "\r\n" => "\n",
    '\\n'  => "\n",
    '\\r'  => "\r",
    '\\t'  => "\t",
    '\\b'  => "\b",
    '\\f'  => "\f",
    '\\('  => '(',
    '\\)'  => ')',
    '\\\\' => '\\',
    "\\\n" => '',
  }

  # Octal character escapes that look like \001 etc
  0.upto(9)   { |n| STRING_ESCAPES['\\00' + n.to_s] = ('00' + n.to_s).oct.chr }
  0.upto(99)  { |n| STRING_ESCAPES['\\0' + n.to_s]  = ('0' + n.to_s).oct.chr }
  0.upto(377) { |n| STRING_ESCAPES['\\' + n.to_s]   = n.to_s.oct.chr }

  def wrap_real(pattern)
    [:real, @sc.scan(pattern).to_f]
  end

  def wrap_int(pattern)
    [:int, @sc.scan(pattern).to_i]
  end

  def wrap_whitespace(pattern)
    @sc.scan(pattern)
    [:whitespace, nil]
  end

  def wrap(pattern)
    [:lit, @sc.scan(pattern).to_sym]
  end

  def consume!(pattern, method_name)
    at = @sc.pos
    return false unless @sc.check(pattern)
    debug { "M: #{method_name} @#{at}: 8 chars after scan pointer #{@sc.peek(8).inspect}" }
    result = send(method_name, pattern)
    @token_stream << result unless result == [:whitespace, nil]
    true
  end

  def parse_ref(start_pattern)
    [:ref, @sc.scan(start_pattern)]
  end

  def parse_array(start_pattern)
    @sc.scan(start_pattern) # consume [
    dict_open_at = @token_stream.length
    walk_scanner(RE[']'])
    raise Malformed, 'Array did not terminate' unless @token_stream.pop == :terminator
    array_items = @token_stream.pop(@token_stream.length - dict_open_at)
    [:array, array_items]
  end

  def parse_dictionary(start_pattern)
    @sc.scan(start_pattern) # consume <<
    dict_open_at = @token_stream.length
    walk_scanner(RE['>>'])
    raise Malformed, 'Dictionary did not terminate' unless @token_stream.pop == :terminator
    dict_items = @token_stream.pop(@token_stream.length - dict_open_at)
    [:dict, dict_items]
  end

  def parse_hex_string(_start_pattern)
    str = @sc.scan(/<[0-9a-f]+>/i)
    raise Malformed, "Malformed hex string at #{@sc.pos}" unless str

    str << '0' unless str.bytesize.even?
    hex_str = str.scan(/../).map { |i| i.hex.chr }.join
    [:hex_string, hex_str]
  end

  def parse_string(_start_pattern)
    # This is murder. PDF allows paired braces to be put into a string literal
    # without any escaping. This means that "(Horrible file format (with a cherry on top))"
    # is a valid string. Needs attention.
    rest_of_string = @sc.scan_until(/[^\\]\)/) # consume everything starting with ( and upto a non-escaped )
    raise Malformed, "String did not terminate (started at at #{@sc.pos})" unless rest_of_string
    rest_of_string[1..-2].gsub(/\\([nrtbf()\\\n]|\d{1,3})?|\r\n?|\n\r/m) do |match|
      STRING_ESCAPES[match] || ''
    end
  end

  def parse_pdf_name(start_pattern)
    name = @sc.scan(start_pattern)
    # Replace #023 hex codes with the corresponding chars
    name_sans_escapes = name.gsub(/\#([\da-fA-F]{1,2})/) do |_hex_code|
      $1.to_i(16).chr
    end
    [:name, name_sans_escapes]
  end

  def garbage(*)
    raise Malformed, "Expected a meaningful token at #{@sc.pos} but did not encounter one"
  end

  def walk_scanner(halt_at_pattern)
    # Limit the iterations to AT MOST (!) once per
    # remaining byte to parse. This ensures we won't
    # have parsing enter an infinite loop where we expect
    # the string scanner to have advanced at least a byte forward
    # but it would sit on the same offset indifinitely.
    (@sc.string.bytesize - @sc.pos).times do
      # Terminate if EOS reached
      break if @sc.eos?

      # Terminate early
      if halt_at_pattern && halted = @sc.scan(halt_at_pattern)
        @token_stream << :terminator
        return
      end

      # Walk through STRATEGIES and stop iterating on first non-false call to consume!
      # STRATEGIES are arranged by order of specificity, so for most iterations
      # somethign meaningful should be hit relatively quickly
      STRATEGIES.find do |pattern, method_name|
        consume!(pattern, method_name)
      end
    end
  end

  def parse(str)
    @sc = StringScanner.new(str)
    @token_stream = []
    walk_scanner(_stop_at_pattern = nil)
    @token_stream
  end

  def debug
    warn(yield)
  end
end
