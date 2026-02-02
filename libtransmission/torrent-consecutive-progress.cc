// This file Copyright © Mnemosyne LLC.
// It may be used under GPLv2 (SPDX: GPL-2.0-only), GPLv3 (SPDX: GPL-3.0-only),
// or any future license endorsed by Mnemosyne LLC.
// License text can be found in the licenses/ folder.

#include "libtransmission/transmission.h"
#include "libtransmission/torrent.h"

float tr_torrent::file_consecutive_progress(tr_file_index_t const file) const
{
    auto const n_files = file_count();
    if (file >= n_files)
    {
        return 0.0F;
    }

    // Initialize cache if needed
    if (file_consecutive_progress_.size() != n_files)
    {
        file_consecutive_progress_.assign(n_files, -1.0F);
    }

    // Return cached value if valid
    if (file_consecutive_progress_[file] >= 0.0F)
    {
        return file_consecutive_progress_[file];
    }

    // Calculate consecutive progress
    auto const [begin_piece, end_piece] = piece_span_for_file(file);
    if (begin_piece >= end_piece)
    {
        file_consecutive_progress_[file] = 1.0F;
        return 1.0F;
    }

    // Count consecutive pieces from the start
    tr_piece_index_t consecutive_pieces = 0;
    for (auto piece = begin_piece; piece < end_piece; ++piece)
    {
        if (has_piece(piece))
        {
            ++consecutive_pieces;
        }
        else
        {
            break;
        }
    }

    auto const total_pieces = end_piece - begin_piece;
    auto const progress = static_cast<float>(consecutive_pieces) / static_cast<float>(total_pieces);
    file_consecutive_progress_[file] = progress;
    return progress;
}

void tr_torrent::update_file_consecutive_progress(tr_piece_index_t const piece)
{
    // Update cache for all files that include this piece
    for (auto [file, file_end] = fpm_.file_span_for_piece(piece); file < file_end; ++file)
    {
        if (file < file_consecutive_progress_.size())
        {
            // Invalidate cache for this file - will be recalculated on next access
            file_consecutive_progress_[file] = -1.0F;
        }
    }
}

void tr_torrent::invalidate_file_consecutive_progress()
{
    file_consecutive_progress_.clear();
}
