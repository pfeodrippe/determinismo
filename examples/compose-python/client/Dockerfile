# SPDX-License-Identifier: MIT
FROM docker.io/library/python:3.12-alpine
COPY sdk/python/determinismo.py /usr/local/lib/python3.12/site-packages/determinismo.py
COPY examples/compose-python/client/bank.py /usr/local/lib/python3.12/site-packages/bank.py
COPY examples/compose-python/client/tests/ /opt/antithesis/test/v1/bank/
RUN chmod +x /opt/antithesis/test/v1/bank/*
CMD ["sleep", "infinity"]
