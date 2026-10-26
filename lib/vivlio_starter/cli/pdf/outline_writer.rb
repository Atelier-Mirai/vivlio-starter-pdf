# frozen_string_literal: true

require "hexapdf"

module VivlioStarter
  module Pdf
    # Internal helper responsible for translating outline entries into HexaPDF structures.
    class OutlineWriter
      # @param doc [HexaPDF::Document] target document
      # @param max_level [Integer] maximum depth allowed in the outline tree
      # @param on_skip [Proc,nil] callback triggered when an entry is ignored
      def initialize(doc, max_level:, on_skip: nil)
        @doc = doc
        @max_level = max_level.to_i.clamp(1, 6)
        @page_count = @doc.pages.count
        @on_skip = on_skip
      end

      # Writes the given +items+ into the document outline.
      #
      # An entry with +:top+ (the y coordinate of the heading, in PDF units) jumps to the
      # heading itself instead of the top of its page, so readers do not have to look for
      # a section that sits near the bottom of the page. Left and zoom stay +nil+ so the
      # reader keeps their own horizontal position and magnification. Entries without
      # +:top+ (chapters, whose opener shows art above the heading) still show the whole page.
      #
      # @param items [Array<Hash>] entries with :level, :text, :page, and optionally :top
      # @return [Integer] number of inserted outline nodes
      def write(items)
        return 0 if @page_count.zero?

        normalized = Array(items).filter_map { normalize_entry(it) }
        return 0 if normalized.empty?

        outline_root = rebuild_outline_root
        stack = [{ level: 0, node: outline_root }]
        inserted = 0

        normalized.each do |entry|
          parent = parent_for(entry[:level], stack)
          destination = resolve_destination(entry[:page], entry[:top])
          unless destination
            warn_skip("page #{entry[:page]} is outside 1-#{@page_count}")
            next
          end

          item = parent.add_item(entry[:text], destination:, open: entry[:level] < @max_level)
          stack << { level: entry[:level], node: item }
          inserted += 1
        end

        if inserted.zero?
          @doc.catalog.delete(:Outlines)
          return 0
        end

        inserted
      end

      private

      # Normalizes a raw hash into a consistent entry structure.
      def normalize_entry(raw)
        text = entry_title(raw)
        return nil if text.nil?

        warn_skip("missing title for outline entry: #{raw.inspect}") if text.empty?
        return nil if text.empty?

        page = fetch(raw, :page, nil).to_i
        if page <= 0
          warn_skip("invalid page for outline entry: #{raw.inspect}")
          return nil
        end

        level = fetch(raw, :level, 1).to_i
        level = 1 if level < 1
        level = @max_level if level > @max_level

        { text:, page:, level:, top: entry_top(raw) }
      end

      # The heading position, or +nil+ to show the whole page. Anything that is not a
      # finite number falls back to the page rather than dropping the entry: a bookmark
      # that lands on the right page is still useful.
      def entry_top(raw)
        top = fetch(raw, :top, nil)
        top.is_a?(Numeric) && top.to_f.finite? ? top.to_f : nil
      end

      # Returns the trimmed title, or +nil+ when the entry must be skipped.
      #
      # A title carrying invalid UTF-8 bytes makes +String#strip+ raise
      # +Encoding::CompatibilityError: invalid byte sequence in UTF-8+. Letting that
      # escape costs the *entire* outline: +add_outline!+ rescues at the top, so one
      # mojibake heading would leave the book with no bookmarks at all. Every other
      # kind of bad entry is skipped one by one through +on_skip+ — this one must
      # behave the same way, and the message has to name the entry so the author can
      # fix the manuscript heading that produced it.
      #
      # Both +EncodingError+ and +ArgumentError+ are caught on purpose: which one
      # Ruby raises for broken bytes depends on the method (+strip+ raises
      # +Encoding::CompatibilityError+, +match?+ raises +ArgumentError+), and that
      # detail must not decide whether the book keeps its bookmarks.
      def entry_title(raw)
        fetch(raw, :text, fetch(raw, :title, nil)).to_s.strip
      rescue EncodingError, ArgumentError
        # +inspect+ is safe here: it escapes invalid bytes (\xFF) instead of raising.
        warn_skip("title is not valid UTF-8, skipping outline entry: #{raw.inspect}")
        nil
      end

      # Fetches a value from the entry by symbol or string key.
      #
      # Entries come from the caller, so a stray String or Integer can end up in the
      # array. Both answer +respond_to?(:[])+ but raise +TypeError+ when indexed with
      # a Symbol (+Integer#[]+ is bit access), which would abort the whole outline —
      # exactly what the per-entry skip exists to prevent. Duck typing is kept so a
      # Hash-like object still works; only the indexing failure falls back.
      def fetch(raw, key, fallback)
        value = (raw[key] || raw[key.to_s] if raw.respond_to?(:[]))
        value.nil? ? fallback : value
      rescue TypeError
        fallback
      end

      # Returns the proper parent node for the requested level.
      def parent_for(level, stack)
        while stack.last[:level] >= level
          break if stack.size == 1
          stack.pop
        end
        stack.last[:node]
      end

      # Resolves the destination for an entry: the heading position when +top+ lies on
      # the page, otherwise the whole page (as before +:top+ existed).
      def resolve_destination(page_number, top = nil)
        index = page_number.to_i - 1
        return nil unless index.between?(0, @page_count - 1)

        page = @doc.pages[index]
        return page unless top && on_page?(page, top)

        { type: :xyz, page:, top: }
      rescue StandardError
        nil
      end

      # A +top+ outside the media box would scroll past the page, so it is not used.
      def on_page?(page, top)
        box = page.box(:media)
        top.between?(box.bottom, box.top)
      end

      # Recreates an empty outline root before inserting new nodes.
      def rebuild_outline_root
        @doc.catalog.delete(:Outlines)
        outline_root = @doc.add({ Type: :Outlines }, type: :Outlines)
        @doc.catalog[:Outlines] = outline_root
        outline_root
      end

      # Emits skip notifications through the provided callback.
      def warn_skip(message)
        @on_skip&.call(message)
      end
    end
  end
end
