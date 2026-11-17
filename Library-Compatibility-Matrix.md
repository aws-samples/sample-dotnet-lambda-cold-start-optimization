# .NET Serverless Modernization — Library Compatibility Matrix

**Companion deliverable for:** *Modernizing .NET to Serverless: Native AOT and SnapStart, Live* **Purpose:** A quick-reference for whether common .NET libraries survive **Native AOT / trimming**, and how they behave under **SnapStart**. Use it to check your dependencies *before* you attempt AOT.

> ⚠️ **Verify against your own build.** AOT/trimming behavior shifts across library and .NET SDK versions. The statuses below are a starting point and the *patterns* are the durable takeaway — confirm the specifics for your versions on your own `dotnet publish`. The presenter should validate every row against the actual demo build before the talk.
>
> Rows that link to a source are backed by vendor, AWS or Microsoft documentation, or by the library's own repository. Rows marked *(observed in this repo)* come from building and deploying this code and have no published source. See [Modernization-Patterns.md](Modernization-Patterns.md) for the full steps.
>
> **"Declares `IsAotCompatible`"** means the library's project file on its default branch sets that property, which turns on the AOT analyzers for the library's own build ([Native AOT deployment](https://learn.microsoft.com/en-us/dotnet/core/deploying/native-aot/#aot-compatibility-analyzers)). Checked November 2026, and not against each released package. It's a strong signal, not a guarantee. Third-party rows weren't published or deployed in this repo.

## Legend

| Symbol | Meaning |
| --- | --- |
| ✅ | AOT/trim-safe — works with little or no change |
| ⚠️ | Works **with care** — needs source generators, annotations, or specific usage patterns |
| ❌ | AOT-hostile today — avoid on AOT paths; use an alternative |
| n/a | Not an AOT concern (runtime/config-level) |

---

## Serialization

| Library | AOT / trim-safe? | SnapStart | Guidance |
| --- | --- | --- | --- |
| System.Text.Json — **source generators** | ✅ | ✅ | Use `JsonSerializerContext` with `[JsonSerializable]`. The recommended path. *(Demo Failure #1 fix.)* |
| System.Text.Json — reflection default | ❌ | ✅ | Reflection-based resolver breaks under trimming. Switch to source-gen. |
| Newtonsoft.Json (Json.NET) | ❌ | ✅ | Heavily reflection-based; not AOT-friendly. Migrate to System.Text.Json source-gen for AOT paths. |

## Dependency Injection

| Library | AOT / trim-safe? | SnapStart | Guidance |
| --- | --- | --- | --- |
| Microsoft.Extensions.DependencyInjection — **explicit registration** | ✅ | ✅ | `AddSingleton<Interface, Impl>()` and `AddSingleton(typeof(Interface), typeof(Impl))` are both trim-safe: each marks the implementation type `[DynamicallyAccessedMembers(PublicConstructors)]`, so its constructors are kept ([dotnet/runtime source](https://github.com/dotnet/runtime/blob/main/src/libraries/Microsoft.Extensions.DependencyInjection.Abstractions/src/ServiceCollectionServiceExtensions.cs)). Prefer the generic form for readability. The `Type` form published with no warning and resolved at runtime *(observed in this repo)*. *(Demo Failure #2's "fix".)* |
| DI via assembly scanning / convention | ❌ | ✅ | Reflection-discovered registrations are invisible to the trimmer. Register explicitly. |
| Scrutor | ❌ | ✅ | Assembly scanning is what the library does, and it doesn't declare `IsAotCompatible`. An open request for Native AOT support has no fix, and the maintainer said Scrutor's fluent API would be hard to move to a source generator ([Scrutor #232](https://github.com/khellang/Scrutor/issues/232)). Replace it with explicit registrations on AOT paths. |
| Third-party containers (Autofac, etc.) | ⚠️ | ✅ | Reflection-heavy; verify AOT support for your version or stick to the built-in container. |

## AWS

| Library | AOT / trim-safe? | SnapStart | Guidance |
| --- | --- | --- | --- |
| AWS SDK for .NET (e.g. AWSSDK.DynamoDBv2) | ⚠️ | ✅ | Emits `IL2xxx` trimming warnings. AWS says the SDK doesn't support trimming, and that parts of libraries can still be trimmed out after the warnings are gone ([Lambda Native AOT](https://docs.aws.amazon.com/lambda/latest/dg/dotnet-native-aot.html#dotnet-native-aot-trimming)). Use the low-level API, keep members with `[DynamicDependency]`, and pair it with `[UnconditionalSuppressMessage]`, since `[DynamicDependency]` alone doesn't silence warnings ([Prepare .NET libraries for trimming](https://learn.microsoft.com/en-us/dotnet/core/deploying/trimming/prepare-libraries-for-trimming)). `TrimmerRootAssembly` is AWS's other lever. Test the deployed function. *(Demo Failure #3.)* |
| AWS Lambda .NET runtime (Amazon.Lambda.*) | ✅ | ✅ | AOT-supported; use the AOT Lambda project template. Note the template sets `TrimMode=partial` because of the AWS SDK ([Getting started](https://docs.aws.amazon.com/lambda/latest/dg/dotnet-native-aot.html#dotnet-native-aot-getting-started)). |
| Amazon.Lambda.AspNetCoreServer | ⚠️ | ✅ | Works; validate trimming on the ASP.NET hosting path for your version. |

## Relational data access *(addressed on the "Most of you are on Postgres/SQL Server" slide)*

| Library | AOT / trim-safe? | SnapStart | Guidance |
| --- | --- | --- | --- |
| **Dapper** | ❌ | ✅ | Plain Dapper relies on reflection and ref-emit, which is what Dapper.AOT exists to replace ([Dapper.AOT](https://aot.dapperlib.dev/)). Fine on SnapStart and the managed runtime. |
| **Dapper.AOT** | ⚠️ | ✅ | Build-time interceptors replace your Dapper calls with generated code, without reflection or ref-emit ([Dapper.AOT](https://aot.dapperlib.dev/)). Dapper itself still had reachable trim-unsafe fallback paths under Native AOT until Sep 2026, so use a current Dapper version ([Dapper #2232](https://github.com/DapperLib/Dapper/issues/2232), [#2233](https://github.com/DapperLib/Dapper/pull/2233)). Verify your queries on a real publish. |
| **Npgsql** (raw ADO.NET) | ⚠️ | ✅ | Usable with care; validate trimming on ADO.NET paths. Persistent connections need RDS Proxy under Lambda scaling. |
| **EF Core** | ❌ | ✅ | AOT-hostile today (heavy reflection / runtime model building). For AOT paths use Dapper.AOT or the RDS Data API. Fine on SnapStart. |
| **RDS Data API** (HTTP) | ✅ | ✅ | No persistent connections — serverless-friendly and AOT-safe. Good relational choice for AOT. |

## Caching and document databases

| Library | AOT / trim-safe? | SnapStart | Guidance |
| --- | --- | --- | --- |
| StackExchange.Redis | ⚠️ | ⚠️ | Doesn't declare `IsAotCompatible`, but the maintainers fixed an AOT-specific bug in Aug 2026 and added an AOT demo project for net8 and net10 ([PR #3158](https://github.com/StackExchange/StackExchange.Redis/pull/3158)). Test on a real publish. On SnapStart, a `ConnectionMultiplexer` created at init is a connection you opened yourself, so check or re-establish it after restore ([Networking best practices](https://docs.aws.amazon.com/lambda/latest/dg/snapstart-best-practices.html#snapstart-networking)). |
| MongoDB.Driver | ❌ | ⚠️ | Doesn't declare `IsAotCompatible`. A PR to annotate the driver for AOT was closed without merging in Oct 2026 ([PR #2146](https://github.com/mongodb/mongo-csharp-driver/pull/2146)), and users have reported serializer failures under .NET 8 AOT ([MongoDB forum](https://www.mongodb.com/community/forums/t/compatibility-issue-with-mongodb-driver-in-net-8-aot-environment/254649)). Use SnapStart instead. Its connection pool is opened by your code, so validate connections after restore. |

## Messaging

| Library | AOT / trim-safe? | SnapStart | Guidance |
| --- | --- | --- | --- |
| RabbitMQ.Client | ⚠️ | ⚠️ | Declares `IsTrimmable` and the trim analyzer for net8+, but not `IsAotCompatible` ([RabbitMQ.Client.csproj](https://github.com/rabbitmq/rabbitmq-dotnet-client/blob/main/projects/RabbitMQ.Client/RabbitMQ.Client.csproj)). Trim-safe isn't the same as AOT-safe; test on a real publish. On SnapStart, re-establish connections opened at init. |
| Confluent.Kafka | ❌ | ⚠️ | An open issue reports producers and consumers failing after a Native AOT publish, with only a community `rd.xml` workaround and no official fix ([#2146](https://github.com/confluentinc/confluent-kafka-dotnet/issues/2146)). Use SnapStart or the managed runtime. Re-establish clients created at init after restore. |

## Resilience and HTTP clients

| Library | AOT / trim-safe? | SnapStart | Guidance |
| --- | --- | --- | --- |
| Polly v8 (`Polly.Core`, `Polly.Extensions`) | ✅ | ✅ | Both declare `IsAotCompatible` ([Polly.Core.csproj](https://github.com/App-vNext/Polly/blob/main/src/Polly.Core/Polly.Core.csproj)), and the project validates AOT in CI ([PR #1745](https://github.com/App-vNext/Polly/pull/1745)). The legacy `Polly` package (v7-style API) doesn't declare it. Use the v8 resilience pipeline API on AOT paths. |
| Refit | ✅ | ✅ | Declares `IsAotCompatible` and `IsTrimmable` ([Refit.csproj](https://github.com/reactiveui/refit/blob/main/src/Refit/Refit.csproj)). Your request and response types still go through System.Text.Json, so give it a source-generated context, as in [Modernization-Patterns.md](Modernization-Patterns.md) Pattern 2. |

## Mapping and mediators

| Library | AOT / trim-safe? | SnapStart | Guidance |
| --- | --- | --- | --- |
| AutoMapper | ⚠️ | ✅ | Doesn't declare `IsAotCompatible`, and no maintainer guidance on AOT turned up in its docs or issues. AutoMapper builds an expression-tree execution plan for each map ([Understanding your mapping](https://docs.automapper.io/en/latest/Understanding-your-mapping.html)), and on Native AOT expression trees always run interpreted, which is slower ([Native AOT limitations](https://learn.microsoft.com/en-us/dotnet/core/deploying/native-aot/)). On AOT paths, prefer hand-written mapping. On SnapStart, prime your maps so building the plan happens before the snapshot. |
| MediatR | ⚠️ | ✅ | Doesn't declare `IsAotCompatible`. The AOT support request was closed for inactivity with no maintainer reply ([MediatR #892](https://github.com/LuckyPennySoftware/MediatR/issues/892)). Handler discovery by assembly scanning has the same problem as the DI scanning row above. Register handlers explicitly, or use a source-generated mediator. |

## API documentation

| Library | AOT / trim-safe? | SnapStart | Guidance |
| --- | --- | --- | --- |
| Swashbuckle.AspNetCore | ❌ | ✅ | A maintainer said full AOT support would amount to a rewrite, and pointed AOT users to `Microsoft.AspNetCore.OpenApi` ([#3913](https://github.com/domaindrivendev/Swashbuckle.AspNetCore/issues/3913)). |
| Microsoft.AspNetCore.OpenApi | ✅ | ✅ | Microsoft documents it as supporting trimming and Native AOT ([Generate OpenAPI documents](https://learn.microsoft.com/en-us/aspnet/core/fundamentals/openapi/aspnetcore-openapi)). Also consider whether a Lambda function needs to serve its own OpenAPI document at all. |

## Connection management *(runtime concern, not AOT)*

| Concern | AOT / trim-safe? | Guidance |
| --- | --- | --- |
| RDS Proxy | n/a | Pools connections so Lambda scaling doesn't exhaust the DB. Use for persistent-connection drivers (Npgsql/EF Core). |
| VPC attachment | n/a | Adds cold-start/networking cost — measure separately; irrelevant to AOT compatibility. |

## Logging / observability

| Library | AOT / trim-safe? | SnapStart | Guidance |
| --- | --- | --- | --- |
| Microsoft.Extensions.Logging | ✅ | ✅ | Works; prefer source-gen logging (`[LoggerMessage]`) for AOT. |
| Serilog | ⚠️ | ✅ | Sink/enricher discovery can be reflection-based; verify your sinks under trimming. |
| NLog 6 | ✅ | ✅ | NLog 6.0 supports AOT builds without warnings ([NLog 6.0 released](https://nlog-project.org/2025/06/21/nlog-6-0-released.html)), and the project declares `IsAotCompatible` for net6+ ([NLog.csproj](https://github.com/NLog/NLog/blob/dev/src/NLog/NLog.csproj)). |
| OpenTelemetry (SDK, OTLP exporter) | ✅ | ✅ | The SDK repo sets `IsAotCompatible` for every net8+ package by default ([Common.prod.props](https://github.com/open-telemetry/opentelemetry-dotnet/blob/main/build/Common.prod.props)). The AspNetCore, Http, AWS and AWSLambda instrumentation packages in the contrib repo declare it too ([AWSLambda instrumentation csproj](https://github.com/open-telemetry/opentelemetry-dotnet-contrib/blob/main/src/OpenTelemetry.Instrumentation.AWSLambda/OpenTelemetry.Instrumentation.AWSLambda.csproj)). Check each contrib package you add, since each one declares it separately. |
| AWS.Lambda.Powertools.Logging | ⚠️ | ✅ | Works, but emits its own `IL2026`/`IL2104`/`IL3053` warnings from its internal serializer and exception handling. Caller code can't fix them: wiring a `TypeInfoResolver` into `AddPowertoolsLogger` and per-`PackageReference` `NoWarn` both had no effect. Only a project-wide `NoWarn` silences them, which is why `reference/03-native-aot-ready` has one *(observed in this repo)*. That `NoWarn` also hides the same codes from your own code. For the fewest warnings, use `context.Logger` with JSON log format ([Structured JSON logging with .NET](https://docs.aws.amazon.com/lambda/latest/dg/csharp-logging.html)). `reference/03-native-aot-single-purpose` drops Powertools for this reason. |

---

## How to read this for your own app

1. **Serialization and DI are almost always fixable** — source generators + explicit registration. Budget for it, don't fear it.
2. **The AWS SDK produces warnings, not walls** — annotate, then test the deployed function. A clean publish doesn't prove nothing was trimmed ([Lambda Native AOT](https://docs.aws.amazon.com/lambda/latest/dg/dotnet-native-aot.html#dotnet-native-aot-trimming)).
3. **EF Core is the real fork in the road.** If a service needs EF Core and must be AOT, that's a rewrite (Dapper.AOT/Data API) — or a signal to use SnapStart instead, which EF Core tolerates fine. MongoDB.Driver, Confluent.Kafka and Swashbuckle are in the same position today.
4. **SnapStart is broadly compatible** — its issues are *restore-time* (uniqueness/connections), not *trim-time*. If AOT compatibility blocks you, SnapStart is the escape hatch.
5. **Check the project file before you trust a library.** A library that declares `IsAotCompatible` runs the AOT analyzers on its own code. One that doesn't may still work, but you're the first line of testing.

## SnapStart restore-time checklist (all libraries)

- [ ] No unique IDs, secrets or random seeds created at init → generate them in the handler or `RegisterAfterRestore`, and use `System.Security.Cryptography.RandomNumberGenerator` for randomness ([Handling uniqueness](https://docs.aws.amazon.com/lambda/latest/dg/snapstart-uniqueness.html)).
- [ ] Connections you opened yourself (DB drivers, raw sockets) → re-establish them in the handler or `RegisterAfterRestore`. Connections opened by an AWS SDK usually resume on their own ([Networking best practices](https://docs.aws.amazon.com/lambda/latest/dg/snapstart-best-practices.html#snapstart-networking)).
- [ ] No temporary credentials or timestamps cached at init and reused → refresh them in the handler before use ([Compatibility considerations](https://docs.aws.amazon.com/lambda/latest/dg/snapstart.html#snapstart-compatibility)).
- [ ] `Dns.GetHostName()` isn't used as an environment ID → every restored environment returns the same value; generate an ID after restore ([Networking best practices](https://docs.aws.amazon.com/lambda/latest/dg/snapstart-best-practices.html#snapstart-networking)).

