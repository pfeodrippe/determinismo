# SPDX-License-Identifier: MIT
FROM mcr.microsoft.com/dotnet/sdk:8.0 AS build
ENV DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1
COPY sdk/dotnet/ /sdk/
COPY tests/antithesis-compat/dotnet/client/Check.cs tests/antithesis-compat/dotnet/client/check.csproj /app/
# The catalog first (DeterminismoCatalog.g.cs: a module initializer declaring every assertion),
# then the program with it.
RUN rm -rf /sdk/*/bin /sdk/*/obj && dotnet run --project /sdk/catalog -- /app && \
    dotnet publish /app/check.csproj -c Release -o /out

FROM mcr.microsoft.com/dotnet/runtime:8.0
COPY --from=build /out/ /app/
COPY tests/antithesis-compat/dotnet/client/sdk/ /opt/antithesis/test/v1/sdk/
RUN chmod +x /opt/antithesis/test/v1/sdk/*
CMD ["sleep", "infinity"]
