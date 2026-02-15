require "cgi"

class HtmlWithRouge < Redcarpet::Render::HTML
  def block_code(code, language)
    language = language&.strip&.downcase
    language = nil if language&.empty?

    lexer = Rouge::Lexer.find(language) || Rouge::Lexers::PlainText.new
    formatter = Rouge::Formatters::HTML.new
    highlighted = formatter.format(lexer.lex(code))

    lang_label = language ? %(<div class="code-lang">#{CGI.escapeHTML(language)}</div>) : ""
    %(<div class="code-block-wrapper">#{lang_label}<pre class="highlight"><code>#{highlighted}</code></pre></div>)
  end
end
