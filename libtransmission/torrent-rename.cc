// This file Copyright © Mnemosyne LLC.
// It may be used under GPLv2 (SPDX: GPL-2.0-only), GPLv3 (SPDX: GPL-3.0-only),
// or any future license endorsed by Mnemosyne LLC.
// License text can be found in the licenses/ folder.

#include <cerrno>
#include <string>
#include <string_view>
#include <vector>

#include <fmt/format.h>

#include "libtransmission/transmission.h"
#include "libtransmission/error.h"
#include "libtransmission/file.h"
#include "libtransmission/torrent.h"
#include "libtransmission/torrent-files.h"
#include "libtransmission/tr-assert.h"
#include "libtransmission/tr-strbuf.h"
#include "libtransmission/utils.h"

using namespace std::literals;

namespace
{
namespace rename_helpers
{
bool renameArgsAreValid(tr_torrent const* tor, std::string_view oldpath, std::string_view newname)
{
    if (std::empty(oldpath) || std::empty(newname) || newname == "."sv || newname == ".."sv || tr_strv_contains(newname, '/'))
    {
        return false;
    }

    auto const newpath = tr_strv_contains(oldpath, '/') ? tr_pathbuf{ tr_sys_path_dirname(oldpath), '/', newname } :
                                                          tr_pathbuf{ newname };

    if (newpath == oldpath)
    {
        return true;
    }

    auto const newpath_as_dir = tr_pathbuf{ newpath, '/' };
    auto const n_files = tor->file_count();

    for (tr_file_index_t i = 0; i < n_files; ++i)
    {
        auto const& name = tor->file_subpath(i);
        if (newpath == name || tr_strv_starts_with(name, newpath_as_dir))
        {
            return false;
        }
    }

    return true;
}

auto renameFindAffectedFiles(tr_torrent const* tor, std::string_view oldpath)
{
    auto indices = std::vector<tr_file_index_t>{};
    auto const oldpath_as_dir = tr_pathbuf{ oldpath, '/' };
    auto const n_files = tor->file_count();

    for (tr_file_index_t i = 0; i < n_files; ++i)
    {
        auto const& name = tor->file_subpath(i);
        if (name == oldpath || tr_strv_starts_with(name, oldpath_as_dir))
        {
            indices.push_back(i);
        }
    }

    return indices;
}

int renamePath(tr_torrent const* tor, std::string_view oldpath, std::string_view newname)
{
    int err = 0;

    auto const base = tor->is_done() || std::empty(tor->incomplete_dir()) ? tor->download_dir() : tor->incomplete_dir();

    auto src = tr_pathbuf{ base, '/', oldpath };

    if (!tr_sys_path_exists(src))
    {
        src += tr_torrent_files::PartialFileSuffix;
    }

    if (tr_sys_path_exists(src))
    {
        auto const parent = tr_sys_path_dirname(src);
        auto const tgt = tr_strv_ends_with(src, tr_torrent_files::PartialFileSuffix) ?
            tr_pathbuf{ parent, '/', newname, tr_torrent_files::PartialFileSuffix } :
            tr_pathbuf{ parent, '/', newname };

        auto tmp = errno;
        bool const tgt_exists = tr_sys_path_exists(tgt);
        errno = tmp;

        if (!tgt_exists)
        {
            tmp = errno;

            if (auto error = tr_error{}; !tr_sys_path_rename(src, tgt, &error))
            {
                err = error.code();
            }

            errno = tmp;
        }
    }

    return err;
}

void renameTorrentFileString(tr_torrent* tor, std::string_view oldpath, std::string_view newname, tr_file_index_t file_index)
{
    auto name = std::string{};
    auto const subpath = std::string_view{ tor->file_subpath(file_index) };
    auto const oldpath_len = std::size(oldpath);

    if (!tr_strv_contains(oldpath, '/'))
    {
        if (oldpath_len >= std::size(subpath))
        {
            name = newname;
        }
        else
        {
            name = fmt::format("{:s}/{:s}"sv, newname, subpath.substr(oldpath_len + 1));
        }
    }
    else
    {
        auto const tmp = tr_sys_path_dirname(oldpath);

        if (std::empty(tmp))
        {
            return;
        }

        if (oldpath_len >= std::size(subpath))
        {
            name = fmt::format("{:s}/{:s}"sv, tmp, newname);
        }
        else
        {
            name = fmt::format("{:s}/{:s}/{:s}"sv, tmp, newname, subpath.substr(oldpath_len + 1));
        }
    }

    if (subpath != name)
    {
        tor->set_file_subpath(file_index, name);
    }
}

} // namespace rename_helpers
} // namespace

void tr_torrent::rename_path_in_session_thread(
    std::string_view const oldpath,
    std::string_view const newname,
    tr_torrent_rename_done_func const& callback,
    void* const callback_user_data)
{
    using namespace rename_helpers;

    auto error = 0;

    if (!renameArgsAreValid(this, oldpath, newname))
    {
        error = EINVAL;
    }
    else if (auto const file_indices = renameFindAffectedFiles(this, oldpath); std::empty(file_indices))
    {
        error = EINVAL;
    }
    else
    {
        error = renamePath(this, oldpath, newname);

        if (error == 0)
        {
            for (auto const& file_index : file_indices)
            {
                renameTorrentFileString(this, oldpath, newname, file_index);
            }

            if (std::size(file_indices) == file_count() && !tr_strv_contains(oldpath, '/'))
            {
                set_name(newname);
            }

            mark_edited();
            set_dirty();
        }
    }

    mark_changed();

    if (callback != nullptr)
    {
        auto const szold = tr_pathbuf{ oldpath };
        auto const sznew = tr_pathbuf{ newname };
        callback(this, szold.c_str(), sznew.c_str(), error, callback_user_data);
    }
}

void tr_torrent::rename_path(
    std::string_view oldpath,
    std::string_view newname,
    tr_torrent_rename_done_func&& callback,
    void* callback_user_data)
{
    this->session->run_in_session_thread(
        [this, oldpath = std::string(oldpath), newname = std::string(newname), cb = std::move(callback), callback_user_data]()
        { rename_path_in_session_thread(oldpath, newname, std::move(cb), callback_user_data); });
}

void tr_torrentRenamePath(
    tr_torrent* tor,
    char const* oldpath,
    char const* newname,
    tr_torrent_rename_done_func callback,
    void* callback_user_data)
{
    oldpath = oldpath != nullptr ? oldpath : "";
    newname = newname != nullptr ? newname : "";

    tor->rename_path(oldpath, newname, std::move(callback), callback_user_data);
}
