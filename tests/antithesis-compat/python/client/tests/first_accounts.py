#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
import bank

redis = bank.Redis()
for account in range(bank.ACCOUNTS):
    redis.call("SET", "account:%d" % account, bank.BALANCE)
