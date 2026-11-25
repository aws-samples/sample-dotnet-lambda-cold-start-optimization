# Modernization Patterns: Applying SVS344 to Real Projects

This repo is a teaching app. This guide turns what it demonstrates into steps
you can apply to your own .NET Lambda Event Functions. It covers three patterns, in
increasing order of effort and cold-start payoff:

1. [SnapStart with priming](#1-snapstart-with-priming)
2. [Native AOT on an ASP.NET Core Lambda](#2-native-aot-on-an-aspnet-core-lambda)
3. [Single-purpose Native AOT function](#3-single-purpose-native-aot-function)

Each pattern points at the directory in this repo that implements it, so you
can diff the before and after yourself.

| Pattern | Before | After |
|---|---|---|
| SnapStart with priming | `02-snapstart/` (plus SnapStart) | `reference/02-snapstart-primed/` |
| Native AOT | `03-native-aot/` (plus `PublishAot`) | `reference/03-native-aot-ready/` |
| Single-purpose AOT | `reference/03-native-aot-ready/` | `reference/03-native-aot-single-purpose/` |

**How claims are sourced.** Statements about AWS or .NET behavior link to the
documentation they come from. Statements about this repo
come from building, deploying and measuring its code. Re-check those against
your own versions.

> To keep the sample focused on cold start, none of the templates here have an
> authorizer. Add IAM, Cognito or a Lambda authorizer before you reuse any of
> them.

---

## Before you start: choose a pattern

| Signal | Pattern |
|---|---|
| You want most of the cold-start win with the least code change | 1. SnapStart |
| You depend on AOT-incompatible libraries (EF Core, Newtonsoft.Json, MongoDB.Driver, assembly scanning) | 1. SnapStart |
| Latency matters and you can invest in trim fixes | 2. Native AOT |
| A hot path deserves its own function, and you want the lowest cold start you can get | 3. Single-purpose AOT |
| Cold starts don't matter for this workload | Stay on the managed runtime |

A common route is SnapStart across the estate now, then AOT for the hot paths
later. Whichever you pick, turning the feature on isn't enough:
SnapStart on .NET pays off most with priming, and AOT needs code fixes.

Check your dependencies against
[Library-Compatibility-Matrix.md](Library-Compatibility-Matrix.md) first.

### Measure before and after

Take a baseline on your current deployment before you change anything, and
hold these constant across every comparison:

- architecture (this repo uses `arm64` everywhere)
- `MemorySize` (2048 in every template here)
- region, payload and sample count (30+ cold samples per variant)

Cold starts come from **concurrent** requests, not repeated ones. An
execution environment finishes one request before it takes the next, so N
overlapping requests need N environments
([Understanding Lambda Event Function scaling](https://docs.aws.amazon.com/lambda/latest/dg/lambda-concurrency.html)).

Record which field each number came from. A SnapStart function's `REPORT`
line has `Restore Duration` and no `Init Duration`, and its cold start is
`Restore Duration + Duration`
([Monitoring for Lambda SnapStart](https://docs.aws.amazon.com/lambda/latest/dg/snapstart-monitoring.html)).
Managed and AOT functions report `Init Duration`. The `bench/` scripts in this
repo handle both, and are a reasonable model for your own harness.

---

## 1. SnapStart with priming

**Reference:** `reference/02-snapstart-primed/`. Compare against
`02-snapstart/`, which is committed as a copy of `01-managed/`. Turning
SnapStart on there, as in Step 1, gives SnapStart without priming.

SnapStart initializes your function when you publish a version, snapshots the
initialized environment, and resumes new environments from that snapshot
([Improving startup performance with Lambda SnapStart](https://docs.aws.amazon.com/lambda/latest/dg/snapstart.html)).
Code that never ran during init isn't warm in the snapshot. On .NET, AWS
recommends invoking your handler from a before-snapshot hook to cut JIT
compilation and assembly loading time
([Maximize Lambda SnapStart performance](https://docs.aws.amazon.com/lambda/latest/dg/snapstart-best-practices.html#snapstart-tuning-dotnet)).
Without that, the JIT cost moves into the first request after each restore.
You can see this by measuring `02-snapstart` with SnapStart on against
`02-snapstart-primed`.

SnapStart supports the managed .NET runtimes, including `dotnet10`, for both
.zip and container image functions. It doesn't support OS-only runtimes (the
`provided` runtimes), provisioned concurrency, Amazon EFS, Amazon S3 Files, or
ephemeral storage above 512 MB
([Supported features and limitations](https://docs.aws.amazon.com/lambda/latest/dg/snapstart.html#snapstart-runtimes)).

### Step 1: Turn SnapStart on, correctly

SnapStart only applies to published versions and to aliases that point at
them, never to `$LATEST`
([Supported features and limitations](https://docs.aws.amazon.com/lambda/latest/dg/snapstart.html#snapstart-runtimes)).
In SAM, `AutoPublishAlias` is what makes SAM generate the
`AWS::Lambda::Version` and `AWS::Lambda::Alias`
([AutoPublishAlias generated resources](https://docs.aws.amazon.com/serverless-application-model/latest/developerguide/sam-specification-generated-resources-function.html#sam-specification-generated-resources-function-autopublishalias)),
so you need **both** properties:

```yaml
OrdersFunction:
  Type: AWS::Serverless::Function
  Properties:
    Runtime: dotnet10
    AutoPublishAlias: live
    SnapStart:
      ApplyOn: PublishedVersions
```

Without `AutoPublishAlias`, the deploy succeeds, no version is published, and
the API event targets `$LATEST`, so SnapStart never applies. With it, SAM also
points the API integration and the Lambda permission at the alias.

Running `aws lambda publish-version` by hand only creates a version when
`$LATEST` has changed since the last published one
([PublishVersion](https://docs.aws.amazon.com/lambda/latest/api/API_PublishVersion.html)).
When it does create one, your alias still points at the old version, and every
version published with SnapStart on is billed for snapshot caching
([SnapStart pricing](https://docs.aws.amazon.com/lambda/latest/dg/snapstart.html#snapstart-pricing)).

If you use CDK or raw CloudFormation, the equivalent is
`SnapStart: { ApplyOn: PublishedVersions }` on the function, plus a published
version (an `AWS::Lambda::Version` resource, or `currentVersion` in CDK).
Make sure every caller invokes that **version or an alias**, never the
unqualified ARN.

### Step 2: Prime through the HTTP pipeline

For ASP.NET Core on `AddAWSLambdaHosting`, register warm-up requests with
`AddAWSLambdaBeforeSnapshotRequest`. It registers itself with
`RegisterBeforeSnapshot`, invokes your handler several times so the runtime
treats it as a hot path, and can be called more than once to add routes
([`ServiceCollectionExtensions.cs`, aws-lambda-dotnet](https://github.com/aws/aws-lambda-dotnet/blob/master/Libraries/src/Amazon.Lambda.AspNetCoreServer.Hosting/ServiceCollectionExtensions.cs)):

```csharp
builder.Services.AddAWSLambdaHosting(LambdaEventSource.RestApi);

builder.Services.AddAWSLambdaBeforeSnapshotRequest(
    new HttpRequestMessage(HttpMethod.Get, "/health"));
builder.Services.AddAWSLambdaBeforeSnapshotRequest(
    new HttpRequestMessage(HttpMethod.Post, "/orders")
    {
        Content = JsonContent.Create(
            new OrderRequest("snapstart-warmup", "snapstart-warmup", 1))
    });
```

The same source notes that the request URI must be relative, the content must
be text, and the handler receives a mock `ILambdaContext` that isn't fully
populated. Don't let priming depend on context values.

A `/health` request alone warms the pipeline but not your serializer, your
services or your SDK client. Prime the routes you actually care about.

### Step 3: Prime the service layer directly

For finer control, add a `RegisterBeforeSnapshot` hook that drives the real
code path several times
([SnapStart runtime hooks for .NET](https://docs.aws.amazon.com/lambda/latest/dg/snapstart-runtime-hooks-dotnet.html)).
This is the shape used in
`reference/02-snapstart-primed/src/OrdersApi/Program.cs`:

```csharp
var app = builder.Build();

var jsonOptions = new JsonSerializerOptions
{
    PropertyNameCaseInsensitive = true,
    PropertyNamingPolicy = JsonNamingPolicy.CamelCase
};

Amazon.Lambda.Core.SnapshotRestore.RegisterBeforeSnapshot(async () =>
{
    using var scope = app.Services.CreateScope();
    var orderService =
        scope.ServiceProvider.GetRequiredService<IOrderService>();
    var warmupRequest =
        new OrderRequest("snapstart-warmup", "snapstart-warmup", 1);
    var warmupJson =
        JsonSerializer.SerializeToUtf8Bytes(warmupRequest, jsonOptions);

    for (var i = 1; i <= 5; i++)
    {
        using var stream = new MemoryStream(warmupJson);
        var request = (await JsonSerializer.DeserializeAsync<OrderRequest>(
            stream, jsonOptions))!;
        var response = await orderService.CreateOrderAsync(request);
        Logger.LogInformation(
            "Priming pass {pass}: {orderId}", i, response.OrderId);
        _ = JsonSerializer.Serialize(response, jsonOptions);
    }
});
```

For ASP.NET Core, register hooks before calling `app.Run()`. For an
executable-assembly handler, register them before `RunAsync`
([Runtime hook registration](https://docs.aws.amazon.com/lambda/latest/dg/snapstart-runtime-hooks-dotnet.html#runtime-hooks-registration-dotnet)).

`reference/02-snapstart-primed` combines both techniques. The requests from
Step 2 prime the HTTP pipeline, and this hook primes the service layer.

Guidelines:

- **Use the same objects your handler uses.** Same `JsonSerializerOptions`,
  same DI-resolved services, same SDK client. Priming a different instance warms
  the JIT but leaves your real client's setup cold.
- **Repeat it.** AWS's .NET example calls the handler 10 times, because tiered
  compilation gives the best results when the handler runs more than once
  ([Maximize Lambda SnapStart performance](https://docs.aws.amazon.com/lambda/latest/dg/snapstart-best-practices.html#snapstart-tuning-dotnet)).
  This repo uses 5. Pick a count your own measurements justify.
- **Stay within the init time limit.** `RegisterBeforeSnapshot` hooks count
  toward initialization time. When Lambda creates a snapshot, that limit is
  130 seconds or the configured function timeout (maximum 900 seconds),
  whichever is higher
  ([SnapStart runtime hooks for .NET](https://docs.aws.amazon.com/lambda/latest/dg/snapstart-runtime-hooks-dotnet.html);
  [Init phase](https://docs.aws.amazon.com/lambda/latest/dg/lambda-runtime-environment.html#runtimes-lifecycle-ib)).
  Restore is a separate limit: the runtime must load and after-restore hooks
  must finish within 10 seconds, or you get a `SnapStartTimeoutException`.

### Step 4: Make priming idempotent

AWS warns that a warm-up invocation must not produce unintended side effects,
such as initiating business transactions
([Maximize Lambda SnapStart performance](https://docs.aws.amazon.com/lambda/latest/dg/snapstart-best-practices.html#snapstart-tuning-dotnet)).
Priming runs your real code every time a version is published, and again
whenever Lambda re-runs initialization to apply software updates
([SnapStart pricing](https://docs.aws.amazon.com/lambda/latest/dg/snapstart.html#snapstart-pricing)).
Lambda also keeps several copies of each snapshot
([SnapStart](https://docs.aws.amazon.com/lambda/latest/dg/snapstart.html)).
A single publish can run the before-snapshot hook more than once, and in this
repo every run writes a real `snapstart-warmup` row to DynamoDB. Assume the
hook runs more than once per deploy.

In a real system:

- Use stub data that is safe to repeat, and is easy to filter or expire
  (a sentinel ID, a TTL attribute).
- Never prime a path with external side effects: payments, emails, queue
  messages to downstream consumers, third-party APIs.
- If the real path has side effects you can't avoid, prime the layers beneath
  it instead (deserialize, validate, build the SDK request) and stop short of
  the call.

### Step 5: Handle state frozen into the snapshot

One snapshot is the starting state for many execution environments, so
anything unique created during init is no longer unique
([Compatibility considerations](https://docs.aws.amazon.com/lambda/latest/dg/snapstart.html#snapstart-compatibility)).
Audit your startup for:

| Frozen at init | What AWS recommends |
|---|---|
| Unique IDs, or seeds for random functions | Generate them in the handler or an after-restore hook, and use a CSPRNG such as `System.Security.Cryptography.RandomNumberGenerator` ([Handling uniqueness](https://docs.aws.amazon.com/lambda/latest/dg/snapstart-uniqueness.html)) |
| Temporary credentials, cached timestamps | Refresh them in the handler before use ([Compatibility considerations](https://docs.aws.amazon.com/lambda/latest/dg/snapstart.html#snapstart-compatibility)) |
| Network connections you opened yourself | Re-establish them in the handler or an after-restore hook. Connections an AWS SDK opens usually resume on their own ([Networking best practices](https://docs.aws.amazon.com/lambda/latest/dg/snapstart-best-practices.html#snapstart-networking)) |
| `Dns.GetHostName()` used as an environment ID | Every restored environment returns the same value. Generate an ID in the handler or after restore instead ([Networking best practices](https://docs.aws.amazon.com/lambda/latest/dg/snapstart-best-practices.html#snapstart-networking)) |

```csharp
Amazon.Lambda.Core.SnapshotRestore.RegisterAfterRestore(() =>
{
    // Regenerate unique state, reconnect, refresh tokens.
    return ValueTask.CompletedTask;
});
```

The Orders API needs no restore hook. It calls `Guid.NewGuid()` inside the
request path, which is generating unique data in the handler, as AWS
recommends. `bench/Send-OrderRequest.ps1` reports duplicate `OrderId`s across
concurrent requests, so you can check this after a restore.

If you register several hooks of one kind, Lambda runs before-snapshot hooks
in reverse registration order and after-restore hooks in registration order
([Runtime hook registration and execution](https://docs.aws.amazon.com/lambda/latest/dg/snapstart-runtime-hooks-dotnet.html#runtime-hooks-registration-dotnet)).
Even so, the code is easier to follow when each before-snapshot step and the
after-restore step that undoes it are registered next to each other.

### Step 6: Verify

- A restore shows `Restore Duration` and `Billed Restore Duration` on the
  `REPORT` line, with no `Init Duration`. For SnapStart functions,
  `Init Duration` appears in the `INIT_REPORT` record, which is written when
  the snapshot is created at publish
  ([Monitoring for Lambda SnapStart](https://docs.aws.amazon.com/lambda/latest/dg/snapstart-monitoring.html)).
- Compare `Restore Duration + Duration` against your managed baseline's
  `Init Duration + Duration`, not restore time alone.
- Fire concurrent requests and check for duplicate IDs or other uniqueness
  failures.

---

## 2. Native AOT on an ASP.NET Core Lambda

**Reference:** `reference/03-native-aot-ready/`. Compare against
`03-native-aot/` with `<PublishAot>true</PublishAot>` added. The app is
ASP.NET Core on `AddAWSLambdaHosting`, running on a Lambda Event Function behind
API Gateway.

Native AOT compiles your app to native code at publish time, so no JIT runs
at startup
([Native AOT deployment](https://learn.microsoft.com/en-us/dotnet/core/deploying/native-aot/)).
Lambda runs Native AOT binaries on the managed .NET runtime
([Compile .NET Lambda Event Function code to a native runtime format](https://docs.aws.amazon.com/lambda/latest/dg/dotnet-native-aot.html)).
Publishing also **trims** code the compiler can't prove is used, so the app
can't rely on unbounded reflection at runtime
([ASP.NET Core support for Native AOT](https://learn.microsoft.com/en-us/aspnet/core/fundamentals/native-aot)).
Most AOT work is making that reflection visible to the compiler.

### Step 1: Enable AOT

```xml
<PropertyGroup>
  <OutputType>Exe</OutputType>
  <PublishAot>true</PublishAot>
  <StripSymbols>true</StripSymbols>
  <InvariantGlobalization>true</InvariantGlobalization>
</PropertyGroup>
```

`InvariantGlobalization` removes globalization-specific code and data
([Trimming options](https://learn.microsoft.com/en-us/dotnet/core/deploying/trimming/trimming-options)).
It shrinks the binary but changes culture-sensitive formatting and comparison,
so confirm your app doesn't depend on non-invariant cultures.

Web SDK projects trim all assemblies by default (`TrimMode` `full`), and
Microsoft recommends fixing trim warnings rather than switching to `partial`
([TrimMode defaults to full for Web SDK projects](https://learn.microsoft.com/en-us/dotnet/core/compatibility/aspnet-core/8.0/trimmode-full)).
This repo leaves `TrimMode` unset, so `full` applies, and its DynamoDB calls
publish without warnings. The AWS SDK for .NET includes Native AOT support
([Platforms supported by the AWS SDK for .NET](https://docs.aws.amazon.com/sdk-for-net/v4/developer-guide/net-dg-supported-platforms.html)).

AWS's Native AOT template sets `partial`, which gives a larger executable
([Getting started](https://docs.aws.amazon.com/lambda/latest/dg/dotnet-native-aot.html#dotnet-native-aot-getting-started)).
If you start with `partial` to get going, plan to move to `full` once your
warnings are fixed.

### Step 2: Read the build-time warnings

```bash
dotnet build -v minimal --no-incremental
```

`PublishAot` turns on dynamic-code analysis during build. At publish, the
whole app, NuGet packages included, is analyzed again
([ASP.NET Core support for Native AOT](https://learn.microsoft.com/en-us/aspnet/core/fundamentals/native-aot)).
Pass `--no-incremental`: an up-to-date build recompiles nothing and reports
no warnings.

With only `PublishAot` set, building this repo's `Program.cs` produces these warnings:

| Warning | Location |
|---|---|
| `IL2026` | `AddAWSLambdaHosting(LambdaEventSource.RestApi)` |
| `IL2026` + `IL3050` | `JsonSerializer.DeserializeAsync<OrderRequest>(context.Request.Body, jsonOptions)` |
| `IL2026` + `IL3050` | `JsonSerializer.Serialize(response, jsonOptions)` |

Microsoft's guidance is that an app with AOT warnings at publish might not work
correctly, and one with none should behave like the JIT build
([ASP.NET Core support for Native AOT](https://learn.microsoft.com/en-us/aspnet/core/fundamentals/native-aot)).
Fix these warnings rather than suppressing them. Steps 3 to 5 cover each one.

### Step 3: Create a source-generated JSON context

Native AOT on Lambda needs source-generated serialization. The context has to
cover your function's input and output types, including the Lambda event types
([Serialization](https://docs.aws.amazon.com/lambda/latest/dg/dotnet-native-aot.html#dotnet-native-aot-serialization)):

```csharp
using System.Text.Json.Serialization;
using Amazon.Lambda.APIGatewayEvents;
using OrdersApi.Models;

namespace OrdersApi;

[JsonSerializable(typeof(OrderRequest))]
[JsonSerializable(typeof(OrderResponse))]
[JsonSerializable(typeof(APIGatewayProxyRequest))]
[JsonSerializable(typeof(APIGatewayProxyResponse))]
[JsonSourceGenerationOptions(
    PropertyNameCaseInsensitive = true,
    PropertyNamingPolicy = JsonKnownNamingPolicy.CamelCase)]
public partial class AppJsonContext : JsonSerializerContext
{
}
```

Checklist for your own context, from
[How to use source generation in System.Text.Json](https://learn.microsoft.com/en-us/dotnet/standard/serialization/system-text-json/source-generation):

- Declare each **root** type you pass to the serializer. Member types are
  picked up automatically. The exception is members typed `object`, whose
  possible runtime types need their own `[JsonSerializable]`.
- Declare a collection only when the collection itself is the root, for
  example `[JsonSerializable(typeof(List<Order>))]`.
- **Reproduce your existing `JsonSerializerOptions`.** Most
  options can be set on `[JsonSourceGenerationOptions]`. Anything you miss
  changes your wire format without an error. The managed variants here read
  requests case-insensitively and write responses in camelCase, so the context
  sets both `PropertyNameCaseInsensitive` and the camelCase naming policy.
  Leave the policy out and the AOT build writes PascalCase instead, with no
  warning. Capture a real
  request and response before the change and diff them after.
- For enum names as strings, put
  `[JsonConverter(typeof(JsonStringEnumConverter<T>))]` on the enum, as
  `OrderStatus` in `00-shared` does. It works with both reflection and source
  generation. The non-generic `JsonStringEnumConverter` isn't supported on
  Native AOT.
- To find leftover reflection use while debugging on the JIT, set
  `<JsonSerializerIsReflectionEnabledByDefault>false</JsonSerializerIsReflectionEnabledByDefault>`.
  Reflection-based calls then throw an `InvalidOperationException` with a
  descriptive message on any runtime. It's already off by default when
  trimming is enabled.

Match the event types to your trigger. `LambdaEventSource.RestApi` uses
`APIGatewayProxyRequest` and `APIGatewayProxyResponse`. An HTTP API uses
`APIGatewayHttpApiV2ProxyRequest` and `APIGatewayHttpApiV2ProxyResponse`
([Amazon.Lambda.APIGatewayEvents](https://github.com/aws/aws-lambda-dotnet/tree/master/Libraries/src/Amazon.Lambda.APIGatewayEvents)).
An ALB uses `ApplicationLoadBalancerRequest` and
`ApplicationLoadBalancerResponse`, which come from a separate package
([Amazon.Lambda.ApplicationLoadBalancerEvents](https://github.com/aws/aws-lambda-dotnet/tree/master/Libraries/src/Amazon.Lambda.ApplicationLoadBalancerEvents)).

Add the packages the context and the hosting fix need:

```xml
<PackageReference Include="Amazon.Lambda.APIGatewayEvents" Version="3.*" />
<PackageReference Include="Amazon.Lambda.Serialization.SystemTextJson" Version="3.*" />
```

This repo uses floating versions (`3.*`) so it picks up fixes. In your project,
pin exact versions or restore with a lock file. If you pin, use 3.0.1 or later
of both packages: their earlier 3.0.x builds for net10.0 weren't marked
trimmable
([aws-lambda-dotnet releases](https://github.com/aws/aws-lambda-dotnet/releases)).

### Step 4: Fix the `AddAWSLambdaHosting` warning

The overload without a serializer uses reflection to serialize Lambda events,
and warns with `IL2026`. Pass a source-generated serializer instead. This is the
same `SourceGeneratorLambdaJsonSerializer<T>` that AWS's Native AOT template
uses
([Getting started](https://docs.aws.amazon.com/lambda/latest/dg/dotnet-native-aot.html#dotnet-native-aot-getting-started)):

```csharp
using Amazon.Lambda.Serialization.SystemTextJson;

// Before: IL2026
builder.Services.AddAWSLambdaHosting(LambdaEventSource.RestApi);

// After
builder.Services.AddAWSLambdaHosting(LambdaEventSource.RestApi,
    new SourceGeneratorLambdaJsonSerializer<AppJsonContext>());
```

The warning text names this overload as the fix.
This is why the context in Step 3 includes the API Gateway event types: the
serializer reads and writes them through `AppJsonContext`.

### Step 5: Fix the `Serialize` and `Deserialize` warnings

Swap each call that passes plain `JsonSerializerOptions` for the overload that
takes a `JsonTypeInfo<T>`
([JsonSerializer methods that use source generation](https://learn.microsoft.com/en-us/dotnet/standard/serialization/system-text-json/source-generation)):

```csharp
// Before: IL2026 + IL3050 on each call
var request = await JsonSerializer.DeserializeAsync<OrderRequest>(
    context.Request.Body, jsonOptions);
var json = JsonSerializer.Serialize(response, jsonOptions);

// After
var request = await JsonSerializer.DeserializeAsync(
    context.Request.Body, AppJsonContext.Default.OrderRequest);
var json = JsonSerializer.Serialize(
    response, AppJsonContext.Default.OrderResponse);
```

A context existing in the project isn't enough. A call has to go through
it: a `JsonTypeInfo<T>`, the context instance, or options whose
`TypeInfoResolver` is set to the context. Passing the `JsonTypeInfo<T>` also
applies the options you set on `[JsonSourceGenerationOptions]`. Search the
whole solution, not only `Program.cs`:

```bash
grep -rn "JsonSerializer\.\(Serialize\|Deserialize\)" --include=*.cs .
```

Minimal API endpoints also serialize for you: bound body parameters, and
anything a handler returns. Register your context so those go through it too
([Minimal APIs and JSON payloads](https://learn.microsoft.com/en-us/aspnet/core/fundamentals/native-aot)):

```csharp
builder.Services.ConfigureHttpJsonOptions(options =>
    options.SerializerOptions.TypeInfoResolverChain.Insert(
        0, AppJsonContext.Default));
```

Or do what this repo does: read the body yourself, and pass a `JsonTypeInfo`
for everything you return, error results included:

```csharp
return Results.Content(json, "application/json; charset=utf-8", statusCode: 200);
return Results.Json(ex.Message, AppJsonContext.Default.String, statusCode: 400);
```

A result such as `Results.BadRequest(message)` serializes through the minimal
API's JSON options. Without a registered context it fails at runtime with a
`NotSupportedException`, and the publish shows no warning for it.

### Step 6: Keep DI registrations visible to the trimmer

Registrations whose types are known at compile time are trim-safe. Both
`AddSingleton<IOrderService, OrderService>()` and
`AddSingleton(typeof(IOrderService), typeof(OrderService))` mark the
implementation type so the trimmer keeps its public constructors
([`ServiceCollectionServiceExtensions.cs`, dotnet/runtime](https://github.com/dotnet/runtime/blob/main/src/libraries/Microsoft.Extensions.DependencyInjection.Abstractions/src/ServiceCollectionServiceExtensions.cs)).
Prefer the generic form, which reads better and is what this repo uses.

The risk is registrations the compiler can't see: assembly scanning (`Scan()`,
Scrutor, convention-based registration) and container features that discover
types by reflection, such as Autofac's assembly scanning. Replace those with
explicit registrations, including
the dependencies of your dependencies.

### Step 7: Publish and handle referenced-assembly warnings

```bash
dotnet publish -c Release -r linux-arm64
```

Publish analyzes the whole app, NuGet packages included, so it can raise
warnings that a clean `dotnet build` never showed
([ASP.NET Core support for Native AOT](https://learn.microsoft.com/en-us/aspnet/core/fundamentals/native-aot)).

Fix warnings in **your own code** where they are raised, preferably by
switching to an API that doesn't need reflection. Microsoft's
[Fixing trim warnings](https://learn.microsoft.com/en-us/dotnet/core/deploying/trimming/fixing-warnings)
covers the annotations and when a suppression is valid, and AWS documents
`TrimmerRootAssembly` for keeping whole assemblies
([Trimming](https://docs.aws.amazon.com/lambda/latest/dg/dotnet-native-aot.html#dotnet-native-aot-trimming)).
In this repo, `OrderRepository.cs` uses the low-level DynamoDB API of the AWS
SDK for .NET V4 and raised no warnings.

Warnings raised **inside a vendor's own code** can't be fixed from yours. In
this repo, `AWS.Lambda.Powertools.Logging` emits warnings from its internal
serializer and exception handling.
`reference/03-native-aot-ready` silences them with a project-wide suppression:

```xml
<TrimmerSingleWarn>true</TrimmerSingleWarn>
<NoWarn>$(NoWarn);IL2026;IL2104;IL3050;IL3053</NoWarn>
```

`NoWarn` is the standard MSBuild way to suppress warning codes.
`TrimmerSingleWarn`, which is already on by default, collapses each package's
warnings into one summary warning per assembly
([Trimming options](https://learn.microsoft.com/en-us/dotnet/core/deploying/trimming/trimming-options)).
The cost is that `NoWarn` applies to the whole publish. `IL2104` and `IL3053`
hide new warnings from **every** package, and `IL2026` and `IL3050` hide them
in your own code too. Add it last, after you've fixed everything you own,
and record which warnings you fixed and which you silenced. A narrower-looking
option doesn't help either: NuGet documents `NoWarn` metadata on a
`PackageReference` for NuGet (`NU*`) warnings, not trimmer warnings
([PackageReference in project files](https://learn.microsoft.com/en-us/nuget/consume-packages/package-references-in-project-files)).

### Step 8: Build for the right OS and architecture

Native AOT can't cross-compile between operating systems. Cross-architecture
builds (x64 to arm64 and back) are supported only when the target's native
toolchain is installed
([Cross-compilation](https://learn.microsoft.com/en-us/dotnet/core/deploying/native-aot/cross-compile)).
For Lambda, AWS requires compiling on Amazon Linux 2023, which the .NET Lambda
CLI does for you in Docker. AWS also strongly recommends building on the same
processor architecture as the function
([Lambda runtime](https://docs.aws.amazon.com/lambda/latest/dg/dotnet-native-aot.html#dotnet-native-aot-runtime)).
`Amazon.Lambda.Tools` requires the host architecture to match the function's
for an AOT build.

With SAM:

```yaml
OrdersFunction:
  Type: AWS::Serverless::Function
  Properties:
    Handler: OrdersApi        # the native executable name
    Runtime: dotnet10
    Architectures:
      - arm64
```

SAM builds with Native AOT when the project sets `PublishAot`, without a
`Metadata: BuildMethod`
([Native AOT with AWS SAM](https://docs.aws.amazon.com/serverless-application-model/latest/developerguide/build-dotnet7.html#build-dotnet7-sam-build)).
The `dotnet10` runtime then runs the native executable directly, because the
handler has no colon and no matching `.dll` is present
([bootstrap.sh, aws-lambda-dotnet](https://github.com/aws/aws-lambda-dotnet/blob/master/Libraries/src/Amazon.Lambda.RuntimeSupport/bootstrap.sh)).

When the host needs it, `Amazon.Lambda.Tools` runs the AOT build in a container
from the `public.ecr.aws/sam/build-dotnet10` image. If that build fails with
"fallback package folder" errors, delete `obj/` and `bin/` first. A host restore
writes absolute local NuGet paths into `obj/`, and those paths don't exist
inside the container. `Deploy-OrdersApi.ps1` clears both folders before every
build for this reason.

A Native AOT binary contains its own stripped-down copy of the .NET runtime
([Native AOT deployment](https://learn.microsoft.com/en-us/dotnet/core/deploying/native-aot/#publish-native-aot-using-the-cli)),
so the patches AWS applies to the `dotnet10` managed runtime don't reach it.
To pick up .NET security fixes, rebuild and redeploy the function. Pull the
build image first, for example
`docker pull public.ecr.aws/sam/build-dotnet10:latest-arm64`, so the build uses
a current .NET SDK.

### Step 9: Verify the deployment, not only the build

Test the AOT app thoroughly and confirm it behaves the same as the JIT build
([ASP.NET Core support for Native AOT](https://learn.microsoft.com/en-us/aspnet/core/fundamentals/native-aot)).
AWS adds that a deployed AOT Lambda needs extra testing to confirm your
libraries work with Native AOT
([Getting started](https://docs.aws.amazon.com/lambda/latest/dg/dotnet-native-aot.html#dotnet-native-aot-getting-started)).

- **Check the package.** If an `OrdersApi.dll` sits beside the native binary,
  the runtime's bootstrap script runs the `.dll` on the JIT instead, with no
  error, because it looks for the `.dll` first
  ([bootstrap.sh](https://github.com/aws/aws-lambda-dotnet/blob/master/Libraries/src/Amazon.Lambda.RuntimeSupport/bootstrap.sh)).
  That looks exactly like "AOT didn't help much."
- **Call every route, error paths included.** Missing serialization metadata
  shows up at runtime, not at build time: a `502` from API Gateway when the
  event can't be read, or a `500` from your handler. Send valid and invalid
  payloads to each endpoint and diff the responses against your managed
  baseline.
- Then measure cold starts with the same settings as your baseline.

---

## 3. Single-purpose Native AOT function

**Reference:** `reference/03-native-aot-single-purpose/`. Compare against
`reference/03-native-aot-ready/`, which does the same work through ASP.NET
Core and Powertools.

Pattern 2 keeps your ASP.NET Core app and makes it AOT-safe. This pattern goes
further: one function for one job, wired straight to the Lambda runtime client,
with only the dependencies that job needs. This is the shape of AWS's own
Native AOT template, a `Main` that starts `LambdaBootstrapBuilder` with a
source-generated serializer
([Getting started](https://docs.aws.amazon.com/lambda/latest/dg/dotnet-native-aot.html#dotnet-native-aot-getting-started)).
Microsoft makes the same point for ASP.NET Core: including fewer features helps
both trimming and AOT
([CreateSlimBuilder](https://learn.microsoft.com/en-us/aspnet/core/fundamentals/native-aot)).
Less framework means less to initialize and fewer referenced assemblies to
trim or suppress.

### When it fits

- A hot path whose cold start you need as low as you can get it.
- The work is a single event type and a single operation (one API route, one
  queue consumer, one S3 handler).
- You can live without ASP.NET Core middleware, routing, model binding and
  framework-level logging on that path.

If a function serves many routes and shares middleware between them, Pattern 2
is usually the better trade.

### Step 1: Carve out the purpose

Pick the one route or event and give it its own function and its own
template resource. Keep the business logic in a shared class library so the
same code backs both the single-purpose function and anything else that
needs it. In this repo, all variants share `00-shared/src/OrdersLib`, and
the single-purpose variant changes only `Program.cs`, the csproj and the
template.

### Step 2: Drop the web SDK and framework packages

```xml
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net10.0</TargetFramework>
    <OutputType>Exe</OutputType>
    <PublishAot>true</PublishAot>
    <StripSymbols>true</StripSymbols>
    <InvariantGlobalization>true</InvariantGlobalization>
  </PropertyGroup>

  <ItemGroup>
    <PackageReference Include="Amazon.Lambda.APIGatewayEvents" Version="3.*" />
    <PackageReference Include="Amazon.Lambda.RuntimeSupport" Version="2.*" />
    <PackageReference Include="Amazon.Lambda.Serialization.SystemTextJson" Version="3.*" />
    <PackageReference Include="Microsoft.Extensions.DependencyInjection" Version="10.*" />
  </ItemGroup>
</Project>
```

Console projects trim all assemblies by default, so switching from the Web SDK
doesn't change trimming behavior
([All assemblies trimmed by default](https://learn.microsoft.com/en-us/dotnet/core/compatibility/deployment/7.0/trim-all-assemblies)).

What changes from Pattern 2:

| Removed | Why |
|---|---|
| `Microsoft.NET.Sdk.Web` | No ASP.NET Core host to start. |
| `Amazon.Lambda.AspNetCoreServer.Hosting` | API Gateway events go straight to your handler. |
| `AWS.Lambda.Powertools.Logging` | Removes its init cost and the vendor trim warnings from Pattern 2, Step 7. |
| `NoWarn` / `TrimmerSingleWarn` | Start with none. Add a suppression only once a publish actually emits a warning you can't fix. |

`Microsoft.Extensions.DependencyInjection` is optional. With only a few services
you could `new` them by hand. Keeping DI here keeps the
registrations the same as in the other variants.

As in Pattern 2, pin exact versions in your own project.

### Step 3: Resolve dependencies during init

Build the object graph at the top of `Program.cs`, outside the handler, so the
SDK client and its configuration are created during init rather than inside
the first request:

```csharp
ServiceCollection services = new();
services.AddSingleton<IAmazonDynamoDB, AmazonDynamoDBClient>();
services.AddSingleton<IOrderValidator, OrderValidator>();
services.AddSingleton<IOrderRepository, OrderRepository>();
services.AddSingleton<IOrderService, OrderService>();

IOrderService orderService = services.BuildServiceProvider()
    .GetRequiredService<IOrderService>();
```

The Pattern 2 rules still apply, such as explicit registrations.

### Step 4: Write a typed handler

Take the Lambda event type directly and return the response type. Without
ASP.NET Core, the handler builds the API Gateway response itself: status code,
`Content-Type` and body. It returns the same responses as the ASP.NET Core
variants, including a `400` with a JSON error message when a malformed body
throws a `JsonException`. `CreateOrderAsync`, `Respond` and `Error` in
`reference/03-native-aot-single-purpose/src/OrdersApi/Program.cs` show the
whole handler. Use the same source-generated `AppJsonContext` as Pattern 2,
including the event types for your trigger.

### Step 5: Start the runtime client with a source-generated serializer

```csharp
await LambdaBootstrapBuilder
    .Create<APIGatewayProxyRequest, APIGatewayProxyResponse>(
        CreateOrderAsync,
        new SourceGeneratorLambdaJsonSerializer<AppJsonContext>())
    .Build()
    .RunAsync();
```

`LambdaBootstrapBuilder` comes from `Amazon.Lambda.RuntimeSupport`, the .NET
client for the
[Lambda Runtime API](https://docs.aws.amazon.com/lambda/latest/dg/runtimes-api.html).
The managed runtime uses the same library
([Amazon.Lambda.RuntimeSupport](https://github.com/aws/aws-lambda-dotnet/tree/master/Libraries/src/Amazon.Lambda.RuntimeSupport)).
`Create` takes your handler and a serializer. The serializer turns the event
JSON into an `APIGatewayProxyRequest` and your `APIGatewayProxyResponse` back
into JSON. `Build()` returns a `LambdaBootstrap`, and `RunAsync()` starts its
invoke loop: fetch the next invocation from the Lambda Runtime API, call your
handler, then send the response, or report the error if the handler throws. The
loop runs for the life of the execution environment, so everything above it in
`Program.cs` runs once, during init.

Passing a `SourceGeneratorLambdaJsonSerializer<AppJsonContext>` is the
single-purpose equivalent of the Pattern 2 `AddAWSLambdaHosting` fix: the event
is deserialized through your context, not by reflection
([Getting started](https://docs.aws.amazon.com/lambda/latest/dg/dotnet-native-aot.html#dotnet-native-aot-getting-started)).

### Step 6: Trim the template to the purpose

Give the function one event, and only the environment variables and
permissions its code uses. `reference/03-native-aot-single-purpose/template.yaml`
has a single `POST /orders` event and one environment variable
(`ORDERS_TABLE_NAME`). Like every template in this repo, its IAM policy allows
only `dynamodb:PutItem` on the table, rather than SAM's `DynamoDBCrudPolicy`,
which also grants read, update and delete
([SAM policy templates](https://docs.aws.amazon.com/serverless-application-model/latest/developerguide/serverless-policy-template-list.html)).

There's no `GET /health` route. A purpose-built function serves only the path
it exists for. If you need health checking, use CloudWatch alarms on errors and
latency, or a synthetic canary against the real route.

### Step 7: Replace what you removed, deliberately

Dropping the framework drops features. Decide what you need back:

| Lost | Lightweight replacement |
|---|---|
| Structured logging (Powertools) | `context.Logger` with the function's log format set to JSON ([Using structured JSON log format with .NET](https://docs.aws.amazon.com/lambda/latest/dg/csharp-logging.html)) |
| Middleware (auth, correlation IDs) | API Gateway authorizers; read headers from `request.Headers` |
| Model validation | Your own validator, as `OrderValidator` does here |
| Routing | One function per route |

Each addition costs startup time, so re-measure after each one.

### Step 8: Publish clean, then verify

Publish with no suppressions and read every `IL` warning. If the publish is
clean, keep it that way. If a warning appears that you can't fix,
add the narrowest suppression that works and note why. Then verify the
deployment the same way as Pattern 2, Step 9: no stray `.dll`, every response
diffed against the baseline, and cold starts measured with identical settings.

---

## Quick reference

| Concern | SnapStart (managed) | Native AOT |
|---|---|---|
| Code change size | Small: hooks in `Program.cs` | Medium: source-generated serialization, plus suppressing library warnings you can't fix |
| Reflection-heavy libraries | Fine | Must be replaced or annotated |
| Cold start metric | `Restore Duration + Duration` | `Init Duration + Duration` |
| Main pitfall | Unprimed paths, frozen unique state | Runtime failures from missing metadata; vendor warnings you can only suppress |
| Build constraint | None | Amazon Linux 2023, on the function's architecture |
| Deploy constraint | Invoke a version or alias, never `$LATEST` | Package must contain no managed `.dll` beside the binary |
| .NET security patches | Applied by AWS to the managed runtime | Rebuild with a current build image and redeploy |

Further reading is in [REFERENCES.md](REFERENCES.md).
