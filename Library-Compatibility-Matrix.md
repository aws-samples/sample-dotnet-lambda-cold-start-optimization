# .NET Serverless Modernization - Library Compatibility Matrix

This companion to the SVS344 code talk shows whether common .NET libraries work with **Native AOT and trimming**, and how they behave under **SnapStart**. Check your dependencies here before you attempt AOT.

> ⚠️ **Verify against your own build.** AOT and trimming behavior changes between library and .NET SDK versions, so these statuses can go out of date as new versions are published. Treat them as a starting point, and confirm them on your own `dotnet publish`.
>
> Rows that link to a source are backed by vendor, AWS or Microsoft documentation, or by the library's own repository. Statements about this repo come from building and deploying its code. "Declares `IsAotCompatible`" means the library's project file on its default branch sets that property, which runs the AOT analyzers on the library's own code ([Native AOT deployment](https://learn.microsoft.com/en-us/dotnet/core/deploying/native-aot/#aot-compatibility-analyzers)). Those checks were made in November 2026. A declaration is a strong signal, not a guarantee.

## Legend

| Symbol | Meaning |
| --- | --- |
| ✅ | AOT/trim-safe: works with little or no change |
| ⚠️ | Works **with care**: needs source generators, annotations, or specific usage patterns |
| ❌ | AOT-hostile today: avoid on AOT paths, and use an alternative |

In the SnapStart column, ⚠️ means the library works, but connections or state it creates during init must be checked or re-created after restore.

---

## Serialization

| Library | AOT / trim-safe? | SnapStart | Guidance |
| --- | --- | --- | --- |
| System.Text.Json: **source generators** | ✅ | ✅ | Use `JsonSerializerContext` with `[JsonSerializable]`. The recommended path. *(The fix in `reference/03-native-aot-ready`.)* |
| System.Text.Json: reflection default | ❌ | ✅ | With trimming, which Native AOT turns on, reflection-based serialization is disabled by default and calls throw `InvalidOperationException` ([Disable reflection defaults](https://learn.microsoft.com/en-us/dotnet/standard/serialization/system-text-json/source-generation#disable-reflection-defaults)). Switch to source generation. |
| Newtonsoft.Json (Json.NET) | ❌ | ✅ | Heavily reflection-based, and it doesn't declare `IsAotCompatible`. Since 13.0.4 it's annotated for trimming and AOT, so the warnings show up at your own call sites ([Json.NET releases](https://github.com/JamesNK/Newtonsoft.Json/releases)). Migrate to System.Text.Json source generation on AOT paths. |

## Dependency Injection

| Library | AOT / trim-safe? | SnapStart | Guidance |
| --- | --- | --- | --- |
| Microsoft.Extensions.DependencyInjection: **explicit registration** | ✅ | ✅ | Trim-safe when the types are known at compile time, because the trimmer keeps the constructors of explicitly registered types. [Pattern 2, Step 6](Modernization-Patterns.md#step-6-keep-di-registrations-visible-to-the-trimmer) has the detail and the source. This repo uses the generic form. |
| DI via assembly scanning / convention | ❌ | ✅ | Reflection-discovered registrations are invisible to the trimmer. Microsoft's guidance suggests registering services explicitly or using source-generated DI ([Fixing trim warnings](https://learn.microsoft.com/en-us/dotnet/core/deploying/trimming/fixing-warnings)). |
| Scrutor | ❌ | ✅ | Assembly scanning is what the library does, and it doesn't declare `IsAotCompatible`. An open request for Native AOT support has no fix, and the maintainer said Scrutor's fluent API would be hard to move to a source generator ([Scrutor #232](https://github.com/khellang/Scrutor/issues/232)). Replace it with explicit registrations on AOT paths. |
| Autofac (and other third-party containers) | ⚠️ | ✅ | Autofac declares `IsAotCompatible`, and its docs say it works with trimming and Native AOT ([Native AOT and trimming](https://autofac.readthedocs.io/en/latest/advanced/native-aot-trimming.html)). Registering concrete types, lambdas and modules is AOT-safe; assembly scanning, `RegisterGeneric` and generated factories raise warnings. Other containers weren't checked, so verify yours or use the built-in container. |

## AWS

| Library | AOT / trim-safe? | SnapStart | Guidance |
| --- | --- | --- | --- |
| AWS SDK for .NET (e.g. AWSSDK.DynamoDBv2) | ✅ | ✅ | The V4 SDK includes Native AOT support ([Platforms supported by the AWS SDK for .NET](https://docs.aws.amazon.com/sdk-for-net/v4/developer-guide/net-dg-supported-platforms.html)). In this repo, the low-level `PutItemAsync` API in `AWSSDK.DynamoDBv2` 4.1 published with no warnings and worked when deployed. |
| AWS Lambda .NET runtime (Amazon.Lambda.*) | ✅ | ✅ | AOT-supported; use the AOT Lambda project template. The template sets `TrimMode=partial`, which gives a larger executable ([Getting started](https://docs.aws.amazon.com/lambda/latest/dg/dotnet-native-aot.html#dotnet-native-aot-getting-started)). This repo uses the default `full` and publishes without SDK warnings. |
| Amazon.Lambda.AspNetCoreServer.Hosting | ⚠️ | ✅ | The `AddAWSLambdaHosting` overload without a serializer relies on reflection and warns under AOT; pass a `SourceGeneratorLambdaJsonSerializer` instead ([ServiceCollectionExtensions.cs](https://github.com/aws/aws-lambda-dotnet/blob/master/Libraries/src/Amazon.Lambda.AspNetCoreServer.Hosting/ServiceCollectionExtensions.cs)). The package declares `IsTrimmable` but not `IsAotCompatible`, so validate the hosting path on a real publish. |

## Relational data access

| Library | AOT / trim-safe? | SnapStart | Guidance |
| --- | --- | --- | --- |
| **Dapper** | ❌ | ✅ | Plain Dapper relies on reflection and ref-emit, which is what Dapper.AOT exists to replace ([Dapper.AOT](https://aot.dapperlib.dev/)). Fine on SnapStart and the managed runtime. |
| **Dapper.AOT** | ⚠️ | ✅ | Build-time interceptors replace your Dapper calls with generated code, without reflection or ref-emit ([Dapper.AOT](https://aot.dapperlib.dev/)). Before Dapper 2.1.89 (Sep 2026), a Dapper.AOT publish still showed trim and AOT warnings from Dapper's own fallback code, so use 2.1.89 or later ([Dapper #2232](https://github.com/DapperLib/Dapper/issues/2232), [#2233](https://github.com/DapperLib/Dapper/pull/2233)). Verify your queries on a real publish. |
| **Npgsql** (raw ADO.NET) | ✅ | ✅ | Supports Native AOT and trimming since 8.0, with the whole library annotated ([Npgsql 8.0 release notes](https://www.npgsql.org/doc/release-notes/8.0.html)). A few features, such as [dynamic JSON mapping of POCOs](https://www.npgsql.org/doc/release-notes/8.0.html#json-poco-and-other-dynamic-features-now-require-an-explicit-opt-in), need opt-ins that warn under AOT. Persistent connections need RDS Proxy under Lambda scaling. |
| **EF Core** | ❌ | ✅ | Native AOT with precompiled queries exists but is experimental, and Microsoft recommends against it in production ([NativeAOT and precompiled queries](https://learn.microsoft.com/en-us/ef/core/performance/nativeaot-and-precompiled-queries)). For AOT paths use Dapper.AOT or the RDS Data API. Fine on SnapStart. |
| **RDS Data API** (HTTP, Aurora only) | ✅ | ✅ | An HTTP API, so there are no persistent connections to manage ([RDS Data API](https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/data-api.html)). You call it through the AWS SDK for .NET V4, which includes Native AOT support. Parse JSON-formatted results through your own source-generated context. |

## Caching and document databases

| Library | AOT / trim-safe? | SnapStart | Guidance |
| --- | --- | --- | --- |
| StackExchange.Redis | ⚠️ | ⚠️ | Doesn't declare `IsAotCompatible`, but the maintainers fixed an AOT-specific bug in Aug 2026 and added an AOT demo project for net8 and net10 ([PR #3158](https://github.com/seredis/StackExchange.Redis/pull/3158)). Test on a real publish. On SnapStart, a `ConnectionMultiplexer` created at init is a connection you opened yourself, so check or re-establish it after restore ([Networking best practices](https://docs.aws.amazon.com/lambda/latest/dg/snapstart-best-practices.html#snapstart-networking)). |
| MongoDB.Driver | ❌ | ⚠️ | Doesn't declare `IsAotCompatible`. Trimming support is an open backlog item with no fix version ([CSHARP-4840](https://jira.mongodb.org/browse/CSHARP-4840)), and users have reported serializer failures under .NET 8 AOT ([MongoDB forum](https://www.mongodb.com/community/forums/t/compatibility-issue-with-mongodb-driver-in-net-8-aot-environment/254649)). Use SnapStart instead. Its connection pool is opened by your code, so validate connections after restore. |

## Messaging

| Library | AOT / trim-safe? | SnapStart | Guidance |
| --- | --- | --- | --- |
| RabbitMQ.Client | ⚠️ | ⚠️ | Declares `IsTrimmable` and the trim analyzer for net8+, but not `IsAotCompatible` ([RabbitMQ.Client.csproj](https://github.com/rabbitmq/rabbitmq-dotnet-client/blob/main/projects/RabbitMQ.Client/RabbitMQ.Client.csproj)). Trim-safe isn't the same as AOT-safe; test on a real publish. On SnapStart, re-establish connections opened at init. |
| Confluent.Kafka | ❌ | ⚠️ | An open issue reports producers and consumers failing after a Native AOT publish, with only a community `rd.xml` workaround and no official fix ([#2146](https://github.com/confluentinc/confluent-kafka-dotnet/issues/2146)). Use SnapStart or the managed runtime. Re-establish clients created at init after restore. |

## Resilience and HTTP clients

| Library | AOT / trim-safe? | SnapStart | Guidance |
| --- | --- | --- | --- |
| Polly v8 (`Polly.Core`, `Polly.Extensions`) | ✅ | ✅ | Both declare `IsAotCompatible` ([Polly.Core.csproj](https://github.com/App-vNext/Polly/blob/main/src/Polly.Core/Polly.Core.csproj)), and the project fixed its AOT issues and validates AOT in CI ([Polly #1737](https://github.com/App-vNext/Polly/pull/1737)). The legacy `Polly` package (v7-style API) doesn't declare it. Use the v8 resilience pipeline API on AOT paths. |
| Refit | ✅ | ✅ | Declares `IsAotCompatible` and `IsTrimmable` ([Refit.csproj](https://github.com/reactiveui/refit/blob/main/src/Refit/Refit.csproj)). Your request and response types still go through System.Text.Json, so give it a source-generated context, as in [Pattern 2, Step 3](Modernization-Patterns.md#step-3-create-a-source-generated-json-context). |

## Mapping and mediators

| Library | AOT / trim-safe? | SnapStart | Guidance |
| --- | --- | --- | --- |
| AutoMapper | ⚠️ | ✅ | Doesn't declare `IsAotCompatible`. AutoMapper builds an expression-tree execution plan for each map ([Understanding your mapping](https://docs.automapper.io/en/latest/Understanding-your-mapping.html)), and on Native AOT expression trees always run interpreted, which is slower ([Native AOT limitations](https://learn.microsoft.com/en-us/dotnet/core/deploying/native-aot/)). On AOT paths, prefer hand-written mapping. On SnapStart, prime your maps so building the plan happens before the snapshot. |
| MediatR | ⚠️ | ✅ | Doesn't declare `IsAotCompatible`. The AOT support request was closed without a fix ([MediatR #892](https://github.com/LuckyPennySoftware/MediatR/issues/892)). Handler discovery by assembly scanning has the same problem as the DI scanning row above. Register handlers explicitly, or use a source-generated mediator. |

## API documentation

| Library | AOT / trim-safe? | SnapStart | Guidance |
| --- | --- | --- | --- |
| Swashbuckle.AspNetCore | ❌ | ✅ | A maintainer said full AOT support would amount to a rewrite, and pointed AOT users to `Microsoft.AspNetCore.OpenApi` ([#3913](https://github.com/domaindrivendev/Swashbuckle.AspNetCore/issues/3913)). |
| Microsoft.AspNetCore.OpenApi | ✅ | ✅ | Microsoft documents it as supporting trimming and Native AOT ([Generate OpenAPI documents](https://learn.microsoft.com/en-us/aspnet/core/fundamentals/openapi/aspnetcore-openapi)). Also consider whether a Lambda Event Function needs to serve its own OpenAPI document at all. |

## Logging and observability

| Library | AOT / trim-safe? | SnapStart | Guidance |
| --- | --- | --- | --- |
| Microsoft.Extensions.Logging | ✅ | ✅ | The standard `ILogger` extension methods are AOT-safe. Source-generated logging with `[LoggerMessage]` is faster ([Compile-time logging source generation](https://learn.microsoft.com/en-us/dotnet/core/extensions/logging/source-generation)). |
| Serilog | ⚠️ | ✅ | Serilog itself declares `IsAotCompatible` ([Serilog.csproj](https://github.com/serilog/serilog/blob/dev/src/Serilog/Serilog.csproj)). Configure sinks in code: loading them from configuration with Serilog.Settings.Configuration uses reflection, isn't annotated yet ([serilog-settings-configuration #371](https://github.com/serilog/serilog-settings-configuration/pull/371)), and has crashed under AOT ([serilog #2084](https://github.com/serilog/serilog/issues/2084)). Check each sink you add. |
| NLog 6 | ✅ | ✅ | NLog 6.0 supports AOT builds without warnings ([NLog 6.0 released](https://nlog-project.org/2025/06/21/nlog-6-0-released.html)), and the project declares `IsAotCompatible` for netstandard2.1 and net6+ ([NLog.csproj](https://github.com/NLog/NLog/blob/main/src/NLog/NLog.csproj)). |
| OpenTelemetry (SDK, OTLP exporter) | ✅ | ✅ | The SDK repo sets `IsAotCompatible` for every net8+ package by default ([Common.prod.props](https://github.com/open-telemetry/opentelemetry-dotnet/blob/main/build/Common.prod.props)). The AspNetCore, Http, AWS and AWSLambda instrumentation packages in the contrib repo declare it too ([AWSLambda instrumentation csproj](https://github.com/open-telemetry/opentelemetry-dotnet-contrib/blob/main/src/OpenTelemetry.Instrumentation.AWSLambda/OpenTelemetry.Instrumentation.AWSLambda.csproj)). Check each contrib package you add, since each one declares it separately. |
| AWS.Lambda.Powertools.Logging | ✅ | ✅ | Works with Native AOT ([AOT support](https://docs.aws.amazon.com/powertools/dotnet/core/logging/#aot-support)). Version 3.3.0 and later publishes without trim or AOT warnings ([3.3.0 release notes](https://github.com/aws-powertools/powertools-lambda-dotnet/releases/tag/3.3.0)). Earlier versions emit `IL2104` / `IL3053` from their own code (checked on 3.2.2). |

---

## How to read this for your own app

1. **Serialization is almost always fixable** with source generators. Plan time for it.
2. **Library warnings you can't fix need a suppression and a test.** Check for a newer library version first. Suppress them only after checking the reflection path, then test the deployed function. A clean publish doesn't prove that nothing you need was trimmed ([Lambda Native AOT](https://docs.aws.amazon.com/lambda/latest/dg/dotnet-native-aot.html#dotnet-native-aot-trimming)).
3. **EF Core is the main deciding factor.** If a service needs EF Core and must be AOT, that's a rewrite (Dapper.AOT/Data API), or a signal to use SnapStart instead, which works with EF Core. MongoDB.Driver, Confluent.Kafka and Swashbuckle are in the same position today.
4. **SnapStart is broadly compatible.** Its issues show up at restore time, with unique state, connections and credentials created during init, rather than at trim time. The [restore-time checklist](Modernization-Patterns.md#step-5-handle-state-frozen-into-the-snapshot) covers them. If AOT compatibility blocks you, SnapStart is the fallback.
5. **Check the project file before you trust a library.** A library that declares `IsAotCompatible` runs the AOT analyzers on its own code. One that doesn't may still work, but you're the first line of testing. To check every dependency at once, set `VerifyReferenceAotCompatibility` in your project: the build then warns (`IL3058`) for each reference built without `IsAotCompatible` ([Native AOT deployment](https://learn.microsoft.com/en-us/dotnet/core/deploying/native-aot/#verify-referenced-assemblies-are-aot-compatible)). That metadata is new in .NET 10, so libraries built against earlier versions show up too. Treat the list as a set of libraries to check, not as failures.
