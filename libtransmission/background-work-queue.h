// This file Copyright © Mnemosyne LLC.
// It may be used under GPLv2 (SPDX: GPL-2.0-only), GPLv3 (SPDX: GPL-3.0-only),
// or any future license endorsed by Mnemosyne LLC.
// License text can be found in the licenses/ folder.

#pragma once

#include <atomic>
#include <condition_variable>
#include <deque>
#include <mutex>
#include <thread>
#include <utility>

template<typename Item>
class BackgroundWorkQueue
{
public:
    void schedule(Item item)
    {
        {
            std::lock_guard const lock(mutex_);
            if (!running_ && !thread_.joinable())
            {
                running_ = true;
                thread_ = std::thread(&BackgroundWorkQueue::run, this);
            }
            items_.push_back(std::move(item));
        }
        cv_.notify_one();
    }

    void shutdown()
    {
        {
            std::lock_guard const lock(mutex_);
            if (!running_)
            {
                return;
            }
            running_ = false;
        }
        cv_.notify_one();
        if (thread_.joinable())
        {
            thread_.join();
        }
    }

    BackgroundWorkQueue() = default;

    BackgroundWorkQueue(BackgroundWorkQueue const&) = delete;
    BackgroundWorkQueue& operator=(BackgroundWorkQueue const&) = delete;

    virtual ~BackgroundWorkQueue()
    {
        {
            std::lock_guard const lock(mutex_);
            running_ = false;
        }
        cv_.notify_one();
        if (thread_.joinable())
        {
            thread_.join();
        }
    }

protected:
    std::atomic<bool> running_{ false };

private:
    virtual auto process(Item& item) -> bool = 0;

    void run()
    {
        while (true)
        {
            Item item;
            {
                std::unique_lock lock(mutex_);
                cv_.wait(lock, [this] { return !running_ || !items_.empty(); });
                if (items_.empty())
                {
                    return;
                }
                item = std::move(items_.front());
                items_.pop_front();
            }
            if (!process(item))
            {
                return;
            }
        }
    }

    std::thread thread_;
    std::mutex mutex_;
    std::condition_variable cv_;
    std::deque<Item> items_;
};
