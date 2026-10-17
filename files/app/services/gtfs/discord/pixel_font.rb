# frozen_string_literal: true

# A tiny bitmap font (8 px high) for the map attribution drawn into the
# Discord map image; chunky_png has no text rendering. Only the characters
# the attribution needs; anything else is skipped.
module Gtfs::Discord::PixelFont
  HEIGHT = 8
  SPACING = 1
  GLYPHS = {
    '©' => %w[.#####. #.....# #.###.# #.#...# #.###.# #.....# .#####. .......],
    ' ' => %w[... ... ... ... ... ... ... ...],
    'O' => %w[.###. #...# #...# #...# #...# #...# .###. .....],
    'S' => %w[.#### #.... #.... .###. ....# ....# ####. .....],
    'M' => %w[#...# ##.## #.#.# #.#.# #...# #...# #...# .....],
    'a' => %w[..... ..... .###. ....# .#### #...# .#### .....],
    'e' => %w[..... ..... .###. #...# ##### #.... .###. .....],
    'n' => %w[..... ..... ####. #...# #...# #...# #...# .....],
    'p' => %w[..... ..... ####. #...# #...# ####. #.... #....],
    'r' => %w[..... ..... #.##. ##..# #.... #.... #.... .....],
    't' => %w[.#... .#... ####. .#... .#... .#..# ..##. .....],
    '-' => %w[.... .... .... #### .... .... .... ....],
    'd' => %w[....# ....# .#### #...# #...# #...# .#### .....],
    'k' => %w[#.... #.... #..#. #.#.. ##... #.#.. #..#. .....],
    'm' => %w[..... ..... ##.#. #.#.# #.#.# #.#.# #.#.# .....],
    'z' => %w[..... ..... ##### ...#. ..#.. .#... ##### .....],
    'ö' => %w[.#.#. ..... .###. #...# #...# #...# .###. .....],
    'ő' => %w[..#.# .#.#. .###. #...# #...# #...# .###. .....],
    'ü' => %w[.#.#. ..... #...# #...# #...# #..## .##.# .....],
    'ű' => %w[..#.# .#.#. #...# #...# #...# #..## .##.# .....]
  }.transform_values(&:freeze).freeze

  module_function

  def width(text)
    glyphs = text.each_char.filter_map { |char| GLYPHS[char] }
    glyphs.sum { |rows| rows.first.size } + ([glyphs.size - 1, 0].max * SPACING)
  end

  # Draws `text` with its top-left corner at (left, top).
  def draw(canvas, text, left, top, color)
    x = left
    text.each_char do |char|
      rows = GLYPHS[char] or next
      rows.each_with_index do |row, dy|
        row.each_char.with_index do |cell, dx|
          canvas.set_pixel_if_within_bounds(x + dx, top + dy, color) if cell == '#'
        end
      end
      x += rows.first.size + SPACING
    end
  end
end
