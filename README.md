# Modernizing .NET to Serverless: Native AOT and SnapStart - Sample App

Companion repo for the AWS re:Invent 2026 code talk SVS344, *"Modernizing .NET to Serverless: Native AOT and SnapStart, live."* The slides and links to documentation and related blog posts can be found on the [SVS344 session page on Serverless Land](https://serverlessland.com/reinvent2026/svs344).

This repo contains a small **Orders API** powered by an AWS Lambda Event Function that runs cleanly on the managed .NET 10 runtime and breaks, by design, when you enable Native AOT. Each fix is a modernization step you would also take on a real app. You can also run it with SnapStart, unprimed and primed, to compare the two.

> **Teaching repo, not a template.** Each chapter's starting point and finished state is a directory you can read, build, and deploy. `03-native-aot/` breaks on purpose once you add `PublishAot`. None of it is meant to be copied into production as-is.
>
> **Looking for the finished code?** It's in [`reference/`](reference): `02-snapstart-primed/`, `03-native-aot-ready/` and `03-native-aot-single-purpose/`.

> **`POST /orders` has no authorizer, but is IP-restricted.** To keep the
> sample focused on cold start, the templates don't attach an authorizer.
> Instead, an API Gateway resource policy accepts `POST /orders` only from the
> address range you deploy with (see
> [IP restriction on POST /orders](#ip-restriction-on-post-orders)). Tear the
> stacks down with `Remove-OrdersApi.ps1` when you're done, and add IAM, Cognito
> or a Lambda authorizer before you reuse a template
> ([Controlling access to a REST API](https://docs.aws.amazon.com/apigateway/latest/developerguide/apigateway-control-access-to-api.html)).

---

## What it does

`POST /orders` → validates the request, persists an order to DynamoDB via the AWS SDK, and returns a confirmation. One endpoint, three injected services and one datastore call: small enough to read in one sitting, with enough moving parts to break under Native AOT.

---

## Chapters and reference variants

The talk has three chapters. Each is a directory at the repo root, committed in
its **starting** state. The talk edits them live, and you can make the same
changes yourself:

| Directory | Configuration | What it shows |
|---|---|---|
| `01-managed/` | Managed runtime (JIT) | The baseline every number is compared against |
| `02-snapstart/` | Managed runtime; you add SnapStart, then priming | SnapStart alone moves the JIT cost into the first invocation instead of removing it |
| `03-native-aot/` | Managed runtime; you add `PublishAot` | The Native AOT failures and their fixes |

The finished state of each chapter that changes is in `reference/`, under the
same number:

| Directory | Configuration | What it shows |
|---|---|---|
| `reference/02-snapstart-primed/` | SnapStart + priming hooks | SnapStart with the JIT work done before the snapshot |
| `reference/03-native-aot-ready/` | `PublishAot`, all fixes | Warning-free publish, deployable, benchmarkable |
| `reference/03-native-aot-single-purpose/` | Native AOT, no ASP.NET Core | Same `POST /orders`; direct API Gateway handler, no ASP.NET Core or Powertools |

`02-snapstart/` and `03-native-aot/` are committed as copies of `01-managed/`, so the repo always starts from a clean managed baseline. `02-snapstart` gets SnapStart and then priming. `03-native-aot` gets `<PublishAot>true</PublishAot>`, which produces the Native AOT warnings and failures described below.

Every variant except `reference/03-native-aot-single-purpose` also exposes a health endpoint on `GET /health`.

---

## Prerequisites

- **.NET 10 SDK**
- **AWS credentials** configured (`aws configure` or SSO), with permissions to deploy AWS SAM applications, including creating IAM roles
- **AWS SAM CLI**
- **An arm64 machine and Docker**, for the Native AOT variants. The managed and SnapStart variants build on any host.
- **PowerShell 7+** (`pwsh`). Every script in this repo is PowerShell, including
  the whole benchmark harness

---

## Repository layout

Shared application code lives once, in `00-shared/`. Each variant directory holds
only what differs between variants.

```
00-shared/src/OrdersLib/        shared application code
  OrdersLib.csproj              one package reference: AWSSDK.DynamoDBv2
  Models/                       OrderRequest, OrderResponse, OrderStatus
  Services/                     interfaces, OrderService, OrderValidator,
                                OrderRepository

01-managed/                     chapter 1; 02- and 03- have the same shape
  template.yaml
  samconfig.toml                committed; holds the stack name
  src/OrdersApi/
    OrdersApi.csproj            ProjectReference to 00-shared
    Program.cs                  host + DI + endpoint; the only application
                                code in a variant
02-snapstart/
03-native-aot/

reference/                      finished states, same shape as a chapter
  02-snapstart-primed/
  03-native-aot-ready/
  03-native-aot-single-purpose/

bench/                          benchmark harness, shared across variants
  internal/                     helpers the top-level scripts call
Modernization-Patterns.md       steps for applying the techniques to real projects
Library-Compatibility-Matrix.md AOT/trim + SnapStart status per library
REFERENCES.md                   further reading
SVS344.slnx                     OrdersLib and all variants
Deploy-OrdersApi.ps1            build + deploy one variant, a subset, or all
Remove-OrdersApi.ps1            delete the stacks (supports -WhatIf)
```

`reference/03-native-aot-ready/src/OrdersApi/` and `reference/03-native-aot-single-purpose/src/OrdersApi/` also have `AppJsonContext.cs`, the source-generated JSON context that fixes the serialization failure.

---

## Quick start

Build everything first. This needs no AWS access and takes about 30 seconds:

```bash
dotnet build SVS344.slnx -v minimal --no-incremental
```

Expect **0 errors and 0 warnings**: `03-native-aot/` is committed as a copy
of `01-managed/`, so Native AOT isn't enabled yet. Add
`<PublishAot>true</PublishAot>` to `03-native-aot/src/OrdersApi/OrdersApi.csproj`
and rebuild to see **warnings, all from `03-native-aot`**: `IL2026` / `IL3050`
on `AddAWSLambdaHosting` and the `JsonSerializer` calls, which is the
serialization failure showing up at build time. You can see it without
deploying anything. Remove the line again before you deploy.

`--no-incremental` is needed because the warnings come from the compiler. An
up-to-date build skips compilation and reports none of them.

Then deploy:

```powershell
./Deploy-OrdersApi.ps1                                  # all variants
./Deploy-OrdersApi.ps1 01-managed, 02-snapstart-primed  # a subset
./Deploy-OrdersApi.ps1 01-managed -AllowedCidr 1.2.3.4/32
```

The Native AOT variants build only on an arm64 machine (see
[Architecture: arm64 everywhere](#architecture-arm64-everywhere)). On an x64
machine, deploy the others:

```powershell
./Deploy-OrdersApi.ps1 01-managed, 02-snapstart, 02-snapstart-primed, 03-native-aot
```

Every requested variant is validated before the first build, so a typo can't
leave the set half-deployed. `POST /orders` is limited to your current public
IP unless you pass `-AllowedCidr`. See
[IP restriction on POST /orders](#ip-restriction-on-post-orders).

Stacks are named `svs344-<variant>`: `svs344-01-managed`, `svs344-02-snapstart`,
`svs344-03-native-aot`, `svs344-02-snapstart-primed`,
`svs344-03-native-aot-ready` and `svs344-03-native-aot-single-purpose`. Each
variant deploys its own DynamoDB table, function and API Gateway REST API, in
its own stack.

Tear down:

```powershell
./Remove-OrdersApi.ps1 -WhatIf          # show what would go, change nothing
./Remove-OrdersApi.ps1                  # prompts per stack
./Remove-OrdersApi.ps1 -Confirm:$false  # skip the prompts
```

> **Destructive.** Deleting a stack removes its function, its API Gateway REST API, **and the
> DynamoDB Orders table along with any data in it.** This can't be undone.
> Start with `-WhatIf`.

---

## IP restriction on POST /orders

Every template takes an `AllowedCidr` parameter (an IPv4 CIDR, such as
`1.2.3.4/32`) and attaches an API Gateway resource policy that denies
`POST /orders` to any other source address. `GET /health` stays open to
everyone. The policy is evaluated by API Gateway before Lambda is invoked, so it
doesn't show up in the `REPORT` lines the cold-start numbers come from.

`Deploy-OrdersApi.ps1` fills the parameter in for you:

```powershell
./Deploy-OrdersApi.ps1 01-managed                              # your public IP, as a /32
./Deploy-OrdersApi.ps1 01-managed -AllowedCidr 1.2.3.4/32   # an address or range you choose
```

Without `-AllowedCidr`, it looks up your public IPv4 address at
`https://checkip.amazonaws.com` and allows that address alone. The lookup runs
once, before the first build, so every stack in the run gets the same range. If
the lookup fails, the script stops. It never falls back to an open range.

A bare `sam deploy` from inside a variant directory has to pass the value
itself. The parameter has no default, so the deploy fails without it:

```bash
sam deploy --parameter-overrides AllowedCidr=1.2.3.4/32
```

Things to know:

- **Redeploy when your IP changes**, for example on a new network or a VPN. A
  changed range takes about a minute to take effect after the deploy finishes.
  Until then, the old range still applies.
- **A `403` means the policy denied you, not that the function is broken.**
  The body reads `User: anonymous is not authorized to perform:
  execute-api:Invoke ... with an explicit deny in a resource-based policy`.
  Check your current IP against the deployed range.
- **Restricting by source IP isn't authentication.** Anyone behind the same
  address, such as a shared office network, can call the API and write
  orders to the stack's DynamoDB table, billed to your account.

---

## Architecture: arm64 everywhere

Every template sets `Architectures: [arm64]`, so all variants run on the same
architecture and their cold-start numbers can be compared directly.

Build every variant with a plain `sam build`, AOT included, which is what
`Deploy-OrdersApi.ps1` does. `sam build --use-container` doesn't work with this
layout: the container mounts only the function's `CodeUri` directory, so the
`ProjectReference` to `00-shared` can't be found and the build fails with
`CS0246`. A build on the host sees the whole repo, and `Amazon.Lambda.Tools`
sets up the Linux AOT build itself when the host needs one.

On the Native AOT path, `Amazon.Lambda.Tools` requires the host architecture to
match the function's, so the AOT variants build only on an arm64 machine. The
managed variants compile to architecture-neutral IL and build from any host.

---

## Native AOT failure and fix

Add `<PublishAot>true</PublishAot>` to `03-native-aot/` and publish, and the
serialization failure below surfaces. Diff `03-native-aot/` against
`reference/03-native-aot-ready/` to see every change at once.

Native AOT turns off reflection-based JSON serialization
([Disable reflection defaults](https://learn.microsoft.com/en-us/dotnet/standard/serialization/system-text-json/source-generation#disable-reflection-defaults)).
The build already warns about it: `IL2026` on `AddAWSLambdaHosting` says
that for Native AOT the overload taking a `SourceGeneratorLambdaJsonSerializer`
must be used, and `IL2026` / `IL3050` flag the handler's `JsonSerializer`
calls. Deployed anyway, the function fails on the first request, before the
handler runs. The default event serializer can't read the API Gateway event,
API Gateway returns a `502`, and the log shows:

```
Amazon.Lambda.Serialization.SystemTextJson.JsonSerializerException: Error converting the Lambda event JSON payload to type Amazon.Lambda.APIGatewayEvents.APIGatewayProxyRequest: Reflection-based serialization has been disabled for this application. Either use the source generator APIs or explicitly configure the 'JsonSerializerOptions.TypeInfoResolver' property.
```

Fix it with a source-generated `JsonSerializerContext`: pass
`SourceGeneratorLambdaJsonSerializer<AppJsonContext>` to
`AddAWSLambdaHosting`, and use the `JsonTypeInfo` overloads in the handler.

The serialization warnings show up on a `dotnet build`. Warnings from a
*referenced* assembly come from the Native AOT compiler (ILC) during publish,
not from the build-time analyzers, which only inspect the project's own code.
With Powertools 3.3.0 or later, `reference/03-native-aot-ready` publishes with
no warnings and no suppression
([3.3.0 release notes](https://github.com/aws-powertools/powertools-lambda-dotnet/releases/tag/3.3.0)).
[Modernization-Patterns.md](Modernization-Patterns.md#step-7-publish-and-handle-referenced-assembly-warnings)
covers what to do if a library you use still warns.

See [Modernization-Patterns.md](Modernization-Patterns.md)
for the reusable patterns,
[Library-Compatibility-Matrix.md](Library-Compatibility-Matrix.md)
for library-by-library status, and [REFERENCES.md](REFERENCES.md) for further
reading.

---

## SnapStart: unprimed and primed

`reference/02-snapstart-primed/template.yaml` sets `AutoPublishAlias: live` and
`SnapStart: ApplyOn: PublishedVersions`. SAM needs both: without
`AutoPublishAlias` it never publishes a version, so SnapStart never applies.
[Modernization-Patterns.md](Modernization-Patterns.md#step-1-turn-snapstart-on-correctly)
explains the setup in full.

`02-snapstart` starts without either property. Adding both to its template
gives SnapStart without priming. Priming then goes into `Program.cs`: `reference/02-snapstart-primed` registers
`AddAWSLambdaBeforeSnapshotRequest` plus a `RegisterBeforeSnapshot` hook that
runs the real order path five times.

Priming runs your real code at every version publish, so it has to be
**idempotent**. To confirm a restore happened, look for `Restore Duration` on
the `REPORT` line with no `Init Duration`.

---

## Invoking the API

```bash
curl -X POST https://<api-url>/orders \
  -H "Content-Type: application/json" \
  -d '{"customerId":"c-123","productId":"p-456","quantity":2}'
```

Expected response:

```json
{
  "orderId": "…",
  "customerId": "c-123",
  "productId": "p-456",
  "quantity": 2,
  "status": "Pending",
  "createdAt": "2026-11-30T00:00:00Z"
}
```

`sam deploy` prints the stack's `ApiUrl` output at the end of each deploy, and
`./bench/internal/Get-StackOutput.ps1 <variant>` shows it later. It ends in
`/Prod`, the stage of the API Gateway REST API. From PowerShell,
`./bench/Send-OrderRequest.ps1 01-managed` sends the same order for you. Call
the API from inside the stack's allowed address range, or you get a `403`
(see [IP restriction on POST /orders](#ip-restriction-on-post-orders)).

---

## Measuring cold start

The scripts in `bench/` take a variant name, such as `02-snapstart-primed`
rather than `reference/02-snapstart-primed`, and find the directory
themselves. `-Variant` is positional and tab-completable, and a typo is
rejected with the list of valid names. Every script has help with examples, for example
`Get-Help ./bench/Measure-ColdStart.ps1 -Full`.

This repo doesn't include benchmark numbers. To measure every variant and
compare them:

```powershell
./bench/Measure-ColdStart.ps1 -Samples 30   # one CSV per variant in bench/results/
./bench/Show-BenchmarkComparison.ps1        # comparison tables from the latest CSVs
```

Or run both steps with one script, which also builds an HTML report of the
results and opens it in your browser:

```powershell
./bench/Start-BenchmarkRun.ps1 -Samples 30
```

Omitting `-Variant` measures every variant. `02-snapstart` and `03-native-aot`
are measured in whatever state their directories are in, so as committed they
measure the same managed app as `01-managed`. To measure fewer variants, pass a
list, for example `-Variant 01-managed, 02-snapstart-primed`.

Measuring all variants in one call gives them the same `-Samples`,
`-Concurrency` and `-Region`. The comparison script warns when a variant has
fewer than 30 cold samples, because a p99 from a handful of samples isn't
meaningful. Architecture and memory size come from the templates: every
template uses arm64 and 2048 MB. If you change either, change it in every
template so the variants stay comparable.

### How the measurement works

- **Concurrency produces cold starts.** An execution environment serves one
  request at a time, so N overlapping requests need N environments.
  `Measure-ColdStart.ps1` forces a cold state once, then sends all samples at the same time.
  Sequential requests would reuse one warm environment.
- **The reset runs once per run, not once per sample.** For a SnapStart
  variant, forcing a cold state means publishing a new version and moving the
  alias, and every publish creates billed snapshots. For the other variants, it
  updates an environment variable on `$LATEST`.
- **Managed and SnapStart cold starts are reported in different fields.** A
  managed or AOT cold start reports `Init Duration`. A SnapStart restore
  reports `Restore Duration` and no `Init Duration`. The CSV keeps both, and
  the comparison script combines them into one series.

### Other scripts

| Script | What it does |
|---|---|
| `Send-OrderRequest.ps1` | Sends concurrent orders to one variant and reports what came back. Duplicate `OrderId`s would mean a random seed was frozen into a SnapStart snapshot. |
| `Get-OrdersApiLog.ps1` | Fetches a variant's recent CloudWatch log events, for example its `REPORT` lines. |
| `Measure-ColdWarmRatio.ps1` | Sends many requests at a fixed concurrency, without forcing cold starts, and reports how many were cold and how many warm. |
| `Start-SnapStartSoakTest.ps1` | Measures `02-snapstart-primed` over several hours, to see whether its restore times fall the longer a version stays deployed. |
| `Start-PowerTuning.ps1` | Starts [AWS Lambda Power Tuning](https://github.com/alexcasalboni/aws-lambda-power-tuning) for the deployed variants to find the best price/performance memory setting. It needs the Power Tuning application deployed as the stack `lambda-power-tuning`, and returns without waiting for the executions to finish. |

---

## Credentials

The scripts use the standard AWS credential chain: set `AWS_PROFILE`, or pass
`-ProfileName` to the PowerShell helpers.

Each variant has a committed `samconfig.toml` that holds its stack name, region
(`us-east-1`) and S3 settings, and is the single source of truth for them. To
deploy to another region, change `region` in both sections of each variant's
file. `resolve_s3 = true` lets SAM manage the artifact bucket. If you're
deploying into a shared account, edit `stack_name` in each variant so you don't
collide with someone else running the same repo.

---

## Security

See [CONTRIBUTING](CONTRIBUTING.md#security-issue-notifications) for more information.

## License

This library is licensed under the MIT-0 License. See the [LICENSE](LICENSE) file.
