#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
import bank
import determinismo as det

redis = bank.Redis()
total = sum(int(redis.call("GET", "account:%d" % account)) for account in range(bank.ACCOUNTS))
det.always(total == bank.ACCOUNTS * bank.BALANCE, "total balance is conserved", {"total": total})
