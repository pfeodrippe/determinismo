# SPDX-License-Identifier: MIT
FROM docker.io/library/python:3.12-alpine
COPY sdk/python/determinismo.py /usr/local/lib/python3.12/site-packages/determinismo.py
COPY tests/antithesis-compat/python/client/bank.py /usr/local/lib/python3.12/site-packages/bank.py
COPY tests/antithesis-compat/python/client/tests/ /opt/antithesis/test/v1/bank/
COPY tests/antithesis-compat/python/client/maze/ /opt/antithesis/test/v1/maze/
RUN chmod +x /opt/antithesis/test/v1/bank/* /opt/antithesis/test/v1/maze/*
CMD ["sleep", "infinity"]
