# Modernizing .NET to Serverless: Native AOT and SnapStart — Sample App

Companion repo for the AWS re:Invent 2026 code talk *"Modernizing .NET to Serverless: Native AOT and SnapStart, Live."*

A small **Orders API** AWS Lambda (.NET 10) that runs clean on the managed runtime and — by design — breaks in three earned ways when you enable Native AOT. Each break is a real modernization lesson: source-generated serialization, explicit DI, and trimming warnings. The same app also deploys in two SnapStart configurations, so you can see why enabling SnapStart is not by itself the win.

> **Teaching repo, not a template.** Every state the talk shows is a directory you can read, build, and deploy — including `03-native-aot/`, which is broken on purpose. Nothing lives in git history: no branches, no tags. Don't copy any of this into production as-is.
>
> **Looking for the finished code?** It's in [`reference/`](reference): `02-snapstart-primed/` and `03-native-aot-ready/`.

> **`POST /orders` is unauthenticated, but IP-restricted.** None of the
> templates attach an authorizer, because it would add its own latency to every
> cold-start number the talk measures. Instead a resource policy accepts
> `POST /orders` only from the source range you deploy with (see
> [IP restriction on POST /orders](#ip-restriction-on-post-orders)). Anyone
> inside that range can still write orders to the stack's DynamoDB table, billed
> to your account. Tear stacks down with `Remove-OrdersApi.ps1` when you're
> done, and add IAM, Cognito or a Lambda authorizer before reusing a template
> (see
> [Controlling access to a REST API](https://docs.aws.amazon.com/apigateway/latest/developerguide/apigateway-control-access-to-api.html)).

---

## What it does

`POST /orders` → validates the request, persists an order to DynamoDB via the AWS SDK, returns a confirmation. One endpoint, three injected services, one datastore call — small enough to read from the back of a room, realistic enough that the failures are earned.

Every variant but `03-native-aot-single-purpose` also exposes `GET /health`.

---

## Chapters and reference variants

The talk has three chapters. Each is a directory at the repo root, committed in
its **starting** state and edited live on stage:

| Directory | Configuration | What it shows |
|---|---|---|
| `01-managed/` | Managed runtime (JIT) | The baseline every number is compared against |
| `02-snapstart/` | SnapStart, no priming | SnapStart moved the JIT cost into your first invocation — it didn't remove it. Priming is added live |
| `03-native-aot/` | Committed identical to `01-managed`; `PublishAot` added live | The three earned failures, fixed live |

Where a chapter changes on stage, its finished state is in `reference/`, under the
same number:

| Directory | Configuration | What it shows |
|---|---|---|
| `reference/02-snapstart-primed/` | SnapStart + priming hooks | The payoff |
| `reference/03-native-aot-ready/` | `PublishAot`, all fixes | Warning-free publish, deployable, benchmarkable |
| `reference/03-native-aot-single-purpose/` | `-ready`, purpose-built | Same `POST /orders`; direct API Gateway handler, no ASP.NET Core or Powertools |

The chapters are numbered because the directory listing is the running order.
Alphabetically, `managed` sorts after `native-aot` and would put AOT before
SnapStart. The number inside `reference/` is a cross-reference to the chapter,
not a position in the talk.

`03-native-aot/` is committed identical to `01-managed/`. On stage, adding exactly one line — `<PublishAot>true</PublishAot>` — produces all three failures. That one-line delta is the point; it isn't in the committed file yet, so the repo always starts from a clean managed baseline.

`03-native-aot-ready` reaches its warning-free publish partly by *suppressing*
AWS SDK warnings rather than fixing them — see Failure #3 below. "Ready" means
the walkthrough's end state, not a production template.

---

## Prerequisites

- **.NET 10 SDK**
- **AWS credentials** configured (`aws configure` or SSO), with permissions for Lambda, DynamoDB, CloudFormation, and S3
- **AWS SAM CLI**
- **Docker**, for the two Native AOT variants
- **PowerShell 7+** (`pwsh`) — every script in this repo is PowerShell, including
  the whole benchmark harness

---

## Repository layout

Shared application code lives once, in `00-shared/`. Each variant directory holds
only what genuinely differs between variants. The shared library carries a `00-`
prefix so it sorts ahead of the variants that reference it — the directory
listing is the reading order.

```
00-shared/src/OrdersLib/        ALL the application code
  OrdersLib.csproj              one package reference: AWSSDK.DynamoDBv2
  Models/                       OrderRequest, OrderResponse, OrderStatus
  Services/                     interfaces, OrderService, OrderValidator,
                                OrderRepository      (unannotated)
                                OrderRepositoryAot   (annotated, 03-native-aot-ready)

01-managed/                     chapter 1; 02- and 03- have the same shape
  template.yaml
  samconfig.toml                committed; holds the stack name
  src/OrdersApi/
    OrdersApi.csproj            ProjectReference to 00-shared
    Program.cs                  host + DI + endpoint — the demo spine, and
                                the only application code in a variant
02-snapstart/
03-native-aot/

reference/                      finished states, same shape as a chapter
  02-snapstart-primed/
  03-native-aot-ready/

bench/                          benchmark harness, shared across variants
  internal/                     helpers the six top-level scripts call
slides/                         SVS344.md plus assets
Modernization-Patterns.md       steps for applying the techniques to real projects
Library-Compatibility-Matrix.md AOT/trim + SnapStart status per library
SVS344.slnx                     all six projects
Deploy-OrdersApi.ps1             build + deploy one variant, a subset, or all
Remove-OrdersApi.ps1             delete the stacks (supports -WhatIf)
```

`reference/03-native-aot-ready/src/OrdersApi/` additionally has `AppJsonContext.cs`.

Scripts take the variant *name* — `02-snapstart-primed`, not
`reference/02-snapstart-primed` — and find the directory themselves.

A variant is its infrastructure plus one `Program.cs`. Three things stay
per-variant: `Program.cs` (Failures #1 and #2, the repository choice, and the
SnapStart hooks), `OrdersApi.csproj` (`PublishAot` and warning suppressions), and
`template.yaml` / `samconfig.toml` (SnapStart config and stack name).

Failure #3 is a DI choice rather than a per-variant file: every variant registers
`OrderRepository` except `03-native-aot-ready`, which registers
`OrderRepositoryAot`. Both live in `00-shared`,
adjacent, differing by one `using` and five attributes — open them side by side
and that diff is the whole fix.

Namespaces stay `OrdersApi.Models` / `OrdersApi.Services` even though the
assembly is `OrdersLib` and the directory is `00-shared`, so every `using` — and
every line the audience reads — is unchanged by the move.

---

## Quick start

Build everything first. This needs no AWS access and takes about 30 seconds:

```bash
dotnet build SVS344.slnx -v minimal --no-incremental
```

Expect **0 errors and 0 warnings** — `03-native-aot/` is committed identical
to `01-managed/`, so Native AOT isn't enabled yet. Add
`<PublishAot>true</PublishAot>` to `03-native-aot/src/OrdersApi/OrdersApi.csproj`
and rebuild to see **5 warnings, all from `03-native-aot`**: `IL2026` / `IL3050`
on `AddAWSLambdaHosting` and the two `JsonSerializer` calls — Failure #1,
surfacing at build time. Useful to know: you can demonstrate the first failure
without deploying anything.

`--no-incremental` matters. Warnings come from the compiler, so an up-to-date
build reports zero of them and tells you nothing.

Then deploy:

```powershell
./Deploy-OrdersApi.ps1                                 # all five
./Deploy-OrdersApi.ps1 01-managed, 02-snapstart-primed  # a subset
./Deploy-OrdersApi.ps1 01-managed -AllowedCidr 203.0.113.0/24
```

Every requested variant is validated before the first build, so a typo can't
leave the set half-deployed. `POST /orders` is limited to your current public
IP unless you pass `-AllowedCidr` — see
[IP restriction on POST /orders](#ip-restriction-on-post-orders).

Stacks are named `svs344-<variant>`: `svs344-01-managed`, `svs344-02-snapstart`,
`svs344-03-native-aot`, `svs344-02-snapstart-primed` and
`svs344-03-native-aot-ready`. Those names live in each variant's committed
`samconfig.toml` and are read by every script, so changing one there is enough.

All five can be deployed at once — each provisions its own DynamoDB table,
Lambda function, and API Gateway under its own stack.

Tear down:

```powershell
./Remove-OrdersApi.ps1 -WhatIf          # show what would go, change nothing
./Remove-OrdersApi.ps1                  # prompts per stack
./Remove-OrdersApi.ps1 -Confirm:$false  # skip the prompts
```

> **Destructive.** Deleting a stack removes its Lambda, API Gateway, **and the
> DynamoDB Orders table along with any data in it.** This can't be undone.
> Start with `-WhatIf`.

---

## IP restriction on POST /orders

Every template takes an `AllowedCidr` parameter (an IPv4 CIDR, such as
`203.0.113.7/32`) and attaches an API Gateway resource policy that denies
`POST /orders` to any other source address. `GET /health` stays open to
everyone. The policy is evaluated by API Gateway before Lambda is invoked, so it
doesn't show up in the `REPORT` lines the cold-start numbers come from.

`Deploy-OrdersApi.ps1` fills the parameter in for you:

```powershell
./Deploy-OrdersApi.ps1 01-managed                             # your public IP, as a /32
./Deploy-OrdersApi.ps1 01-managed -AllowedCidr 203.0.113.0/24  # a range you choose
```

Without `-AllowedCidr`, it looks up your public IPv4 address at
`https://checkip.amazonaws.com` and allows that address alone. The lookup runs
once, before the first build, so every stack in the run gets the same range. If
the lookup fails, the script stops. It never falls back to an open range.

A bare `sam deploy` from inside a variant directory has to pass the value
itself. The parameter has no default, so the deploy fails without it:

```bash
sam deploy --parameter-overrides AllowedCidr=203.0.113.7/32
```

Things to know:

- **Redeploy when your IP changes**, for example on venue Wi-Fi or a VPN. A
  changed range takes about a minute to take effect after the deploy finishes.
  Until then, the old range still applies.
- **A `403` means the policy denied you, not that the function is broken.**
  The body reads `User: anonymous is not authorized to perform:
  execute-api:Invoke ... with an explicit deny in a resource-based policy`.
  Check your current IP against the deployed range.
- **Each template declares the API explicitly, with `AlwaysDeploy: true`.**
  API Gateway applies a resource policy change only on a new deployment
  ([Troubleshoot your resource policy](https://docs.aws.amazon.com/apigateway/latest/developerguide/apigateway-resource-policies-create-attach.html#apigateway-resource-policies-troubleshoot-deploy)),
  and SAM's change detection doesn't see the parameter value. Without
  `AlwaysDeploy`, a new range would never take effect and the old one would
  keep access.
- **Restricting by source IP isn't authentication.** Anyone behind the same
  address, such as a shared office or venue NAT, can call the API.

---

## Architecture: arm64 everywhere

Every template sets `Architectures: [arm64]`. Keep it that way — a
cross-architecture comparison isn't a comparison, and the head-to-head table is
the slide people photograph.

Build every variant with a plain `sam build`, AOT included. `Deploy-OrdersApi.ps1`
does exactly that.

**Don't add `--use-container`.** It mounts only the `CodeUri` directory, so the
`ProjectReference` up to `00-shared` lands outside the container and the
build fails with `CS0246: The type or namespace name 'OrdersApi' could not be
found`, preceded by `MSB9008 ... does not exist`. That error looks like a broken
reference but the reference is fine — the shared project simply isn't in the
mount. Building on the host keeps the whole repo visible, and `Amazon.Lambda.Tools`
arranges a Linux AOT build itself when the host needs one.

One constraint to know: on the Native AOT path Lambda.Tools requires the host
architecture to match the function's, so the two AOT variants build only on a machine
matching their `Architectures`. The managed variants compile to
architecture-neutral IL and build for arm64 from any host.

---

## The three earned failures

Open `03-native-aot/` and publish — the three failures surface in order.
`reference/03-native-aot-ready/` has the same three locations marked
`// FIX #N:` — diff the two directories to see all three changes at once.

1. **Serialization** — the trimmer deletes the DTO property getters, because
   nothing calls them statically and reflection isn't a caller it can see. Fix
   with a source-generated `JsonSerializerContext` and the `JsonTypeInfo`
   overloads.
2. **Reflection-based DI** — constructors go the same way as the getters. The
   `AddSingleton(Type, Type)` overload defers discovery to reflection; explicit
   `AddSingleton<IFoo, Foo>()` is statically visible, so the trimmer keeps it.
3. **Trimming warnings** — the AWS SDK emits `IL2xxx`. Resolve with
   `[DynamicDependency]` and, where the reflection path is verified safe,
   `[UnconditionalSuppressMessage]`. Compare
   `00-shared/src/OrdersLib/Services/OrderRepository.cs` with
   `OrderRepositoryAot.cs` beside it.

Failures #1 and #2 show up on a `dotnet build`. Failure #3 needs a
`dotnet publish` — trim warnings from a *referenced* assembly come from ILLink
during publish, not from the build-time analyzers, which only inspect the
project's own code.

> **Don't add `NoWarn` to `03-native-aot`.** `reference/03-native-aot-ready`
> suppresses `IL2026;IL2104;IL3050;IL3053`. Copy that across and Failure #3
> goes silent — you'd flip `PublishAot`, see #1 and #2, then nothing. The
> absence is load-bearing and is commented as such in the csproj.

See [Modernization-Patterns.md](Modernization-Patterns.md)
for the reusable recipes and
[Library-Compatibility-Matrix.md](Library-Compatibility-Matrix.md)
for library-by-library status.

---

## SnapStart: unprimed and primed

Both SnapStart templates set **two** properties:

```yaml
AutoPublishAlias: live
SnapStart:
  ApplyOn: PublishedVersions
```

Both are required. `SnapStart: ApplyOn` alone is a silent no-op in SAM: without
`AutoPublishAlias`, SAM never publishes a version, and the API event targets the
unqualified ARN — `$LATEST` — which never gets SnapStart. `AutoPublishAlias` also
repoints the API integration and the Lambda permission at the alias.

Because `AutoPublishAlias` publishes on every deploy, don't run
`aws lambda publish-version` by hand afterwards — that creates an orphan version
the alias doesn't point at, plus another round of billed snapshot creation (one
per AZ, not one total).

The difference between the two variants is `Program.cs`:

- `reference/02-snapstart-primed` registers `AddAWSLambdaBeforeSnapshotRequest`
  plus a `RegisterBeforeSnapshot` hook that runs the real order path ten times.
- `02-snapstart` has neither, on purpose — that is the chapter's starting state.

Priming has to be **idempotent** — it runs your handler for real at every
version publish.

To confirm a restore actually happened, look for `Restore Duration` on the
`REPORT` line with `Init Duration` absent. `INIT_REPORT` proves snapshot
*creation* at publish time, not a restore.

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

`ApiUrl` ends in `/Prod` — these are API Gateway **REST** APIs
(`Events: Type: Api`), declared as `OrdersRestApi` in each template.

Run the `curl` from inside the stack's allowed range. Anywhere else,
`POST /orders` returns `403` with `... with an explicit deny in a
resource-based policy`.

---

## Measuring cold start

Bench scripts take a **variant name**, not a stack name. `-Variant` is
positional and tab-completable, and a typo is rejected with the valid list.

```powershell
./bench/Measure-ColdStart.ps1 -Samples 30               # -> results/<variant>.cold.<UTC stamp>.n30.csv
./bench/Measure-ColdStart.ps1 01-managed -Samples 30    # -> results/01-managed.cold.<UTC stamp>.n30.csv
./bench/Show-BenchmarkComparison.ps1                    # comparison tables
./bench/Show-BenchmarkComparison.ps1 -AsOf 2026-10-01T14:32:00Z  # an earlier run

./bench/Send-OrderRequest.ps1 02-snapstart-primed -Count 50
./bench/Get-OrdersApiLog.ps1 02-snapstart-primed -Minutes 5 -Pattern REPORT
```

`Measure-ColdStart.ps1` is the suite: per variant, reset once, fire N concurrent
requests, scrape the REPORT lines, write the CSV. `-Variant` takes a list and
defaults to every measurable variant, so omitting it — or naming two, like
`01-managed,03-native-aot-ready` — measures them all with the same settings. The
other two are for poking at one variant by hand.

`Send-OrderRequest.ps1` dispatches every request before awaiting any, so they're
genuinely in flight together — that's what forces new environments. It also
reports duplicate `OrderId`s, which is how you catch a frozen random seed after
a SnapStart restore.

Everything under `bench/internal/` is called by the scripts above rather than run
directly, though two are useful on their own when something looks wrong:

```powershell
./bench/internal/Get-StackOutput.ps1 03-native-aot-ready       # function / API URL
./bench/internal/Reset-ExecutionEnvironment.ps1 01-managed     # next invoke cold
```

Two more, for different questions:

```powershell
./bench/Measure-ColdWarmRatio.ps1 -Invocations 500 -Concurrency 10  # -> results/<variant>.coldwarm.<UTC stamp>.n500.csv
./bench/Start-PowerTuning.ps1                 # best price/performance memory
```

`Measure-ColdWarmRatio.ps1` deliberately does *not* force cold starts — it
hammers the function at a natural concurrency to see how Lambda reuses
environments under load. Use `Measure-ColdStart.ps1` when you want cold samples
on purpose. `Show-BenchmarkComparison.ps1` prints two tables, each from the
latest file per variant: cold p50/p99 and cold total from the forced-cold run,
cold-% under load and warm duration from the cold/warm run. Each table has a
`Measured at` row, and `-AsOf` shows an earlier point in time.

Every script supports `Get-Help`, including examples:

```powershell
Get-Help ./bench/Measure-ColdStart.ps1 -Full
```

Two mechanics worth understanding before trusting the output.

**Concurrency produces cold starts, not repetition.** An execution environment
serves one request at a time, so N *overlapping* requests need N environments.
The suite forces one cold state and then fires all samples concurrently.
Invoking sequentially would reuse one warm environment and yield a single sample.
That's also why the reset runs once per suite, not once per sample: for a
SnapStart variant it publishes a version, and one publish creates a billed
snapshot in *each* of several Availability Zones — verified by logging the AZ id
from inside the before-snapshot hook, which ran twice for one publish.

**Init and Restore are different fields.** A managed cold start reports
`Init Duration`; a SnapStart restore reports `Restore Duration` and no
`Init Duration`. The CSV carries both columns and the comparison script folds them into
one comparable series, reporting which it measured.

The reset adapts per variant by querying `SnapStart.ApplyOn` rather than
guessing from the name. With SnapStart off it bumps an env var on `$LATEST`
(merged into the existing map, not replacing it). With SnapStart on that would
force nothing — the alias serves an immutable version — so it publishes a new
version and moves the alias.

Aim for at least 30 cold samples per variant. The comparison script warns below that,
because a p99 from a handful of samples isn't a number to put on a slide.

### Benchmark results

No committed numbers. The previous table in this README was generated before the
variants were unified on arm64 and before the CSV schema changed, so it can't be
reproduced and has been removed rather than left to be trusted.

Generate your own:

```powershell
./bench/Measure-ColdStart.ps1 -Samples 30
./bench/Show-BenchmarkComparison.ps1
```

Omitting `-Variant` measures `01-managed`, `02-snapstart` (unprimed, as
committed), `02-snapstart-primed` and `03-native-aot-ready`. `03-native-aot` is
left out on purpose — as committed it returns 502 by design, so it has no honest
number to contribute. Name it explicitly if you want to watch it fail.

Measure every variant in one call rather than looping by hand. `-Samples`,
`-Concurrency` and `-Region` are single-valued, so they apply to every variant
by construction — which is the whole basis of the comparison. Re-run one variant
separately at a different sample count and you've quietly put a 50-sample p99 in
a table of 30-sample ones. A bare `foreach` also stops at the first failure and
loses the variants after it, minutes of already-successful work included.

Architecture and memory size are the two you still have to hold constant
yourself, in the templates. Record whether each number came from `Init` or
`Restore`.

### Power tuning

`bench/Start-PowerTuning.ps1` runs the
[AWS Lambda Power Tuning](https://github.com/alexcasalboni/aws-lambda-power-tuning)
state machine against each deployed variant to find the best price/performance
memory setting. It resolves the state machine ARN from the
`lambda-power-tuning` stack's `StateMachineARN` output and each variant's Lambda
ARN from its stack's `OrdersFunctionArn` output.

```powershell
./bench/Start-PowerTuning.ps1                                   # every deployed variant
./bench/Start-PowerTuning.ps1 01-managed, 03-native-aot-ready    # a subset
./bench/Start-PowerTuning.ps1 03-native-aot-ready -PowerValues 512, 1024, 2048
```

Requires the Power Tuning application deployed as stack `lambda-power-tuning`
(override with `-PowerTuningStack`) and at least one variant stack deployed.
Variants whose stack isn't deployed are skipped with a warning; any *other*
failure stops the run rather than being mistaken for "not deployed".

It starts executions and returns immediately — it does not wait. Each returned
object carries the `ExecutionArn`.

---

## Credentials

No profile names, account IDs, or ARNs are committed anywhere. The scripts use
the standard AWS credential chain — set `AWS_PROFILE`, or pass `-ProfileName` to
the PowerShell helpers.

`samconfig.toml` **is** committed, one per variant, and is the single source of
truth for stack names, region, and S3 settings. There's nothing sensitive in it:
`resolve_s3 = true` means no bucket name is baked in. If you're deploying into a
shared account, edit `stack_name` in each variant so you don't collide with
someone else running the same repo.

---

## Related docs

- [Modernization patterns](Modernization-Patterns.md) — reusable fix recipes
- [Library compatibility matrix](Library-Compatibility-Matrix.md) — AOT/trim + SnapStart status per library

## License

Sample code for educational purposes. See `LICENSE`.
