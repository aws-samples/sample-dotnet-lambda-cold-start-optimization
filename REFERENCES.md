# References

Further reading for SVS344, *Modernizing .NET to Serverless: Native AOT and
SnapStart, Live*.

## SnapStart

- [Improving startup performance with Lambda SnapStart](https://docs.aws.amazon.com/lambda/latest/dg/snapstart.html)
  (AWS docs). Start here: what SnapStart is, which runtimes support it, and
  how to turn it on.
- [Under the hood: how AWS Lambda SnapStart optimizes function startup latency](https://aws.amazon.com/blogs/compute/under-the-hood-how-aws-lambda-snapstart-optimizes-function-startup-latency/)
  (AWS Compute Blog). How snapshots are created, cached and restored. The
  lifecycle and cache diagrams in the talk come from this post.
- [Improving SnapStart Performance in .NET Lambda Functions](https://aws.amazon.com/blogs/dotnet/blog-improving-snapstart-performance-in-net-lambdas/)
  (.NET on AWS Blog). Priming techniques for .NET workloads, with
  measurements before and after.
- [Maximize Lambda SnapStart performance](https://docs.aws.amazon.com/lambda/latest/dg/snapstart-best-practices.html)
  (AWS docs). Best practices for getting the most out of a snapshot.
- [Lambda SnapStart runtime hooks for .NET](https://docs.aws.amazon.com/lambda/latest/dg/snapstart-runtime-hooks-dotnet.html)
  (AWS docs). The before-snapshot and after-restore hooks used for priming
  and for resetting state.
- [Handling uniqueness with Lambda SnapStart](https://docs.aws.amazon.com/lambda/latest/dg/snapstart-uniqueness.html)
  (AWS docs). Why random values created at init end up shared by every
  restored environment, and how to avoid it.

## Native AOT

- [.NET 10 runtime now available in AWS Lambda](https://aws.amazon.com/blogs/compute/net-10-runtime-now-available-in-aws-lambda/)
  (AWS Compute Blog). The launch post for `dotnet10`, the runtime every
  variant in the talk uses. Covers file-based C# functions, which publish as
  Native AOT by default, and the Native AOT improvements in .NET 10.
- [Compile .NET Lambda function code to a native runtime format](https://docs.aws.amazon.com/lambda/latest/dg/dotnet-native-aot.html)
  (AWS docs). Building and deploying a .NET Lambda function with Native AOT.
- [Native AOT deployment overview](https://learn.microsoft.com/en-us/dotnet/core/deploying/native-aot/)
  (Microsoft Learn). What `PublishAot` does, and its limitations.
- [How to use source generation in System.Text.Json](https://learn.microsoft.com/en-us/dotnet/standard/serialization/system-text-json/source-generation)
  (Microsoft Learn). The fix for the serialization failure:
  `JsonSerializerContext` and `[JsonSerializable]`.
- [Fixing trim warnings](https://learn.microsoft.com/en-us/dotnet/core/deploying/trimming/fixing-warnings)
  (Microsoft Learn). How to read and resolve `IL2xxx` warnings like the ones
  the AWS SDK raises in the talk.

## Videos

- [AWS re:Invent 2024 - Accelerate Python and .NET Lambda functions with SnapStart (SVS218-NEW)](https://www.youtube.com/watch?v=D3IOL_mNrFM)
  (AWS Events, YouTube, 48 min). The re:Invent 2024 session on SnapStart for
  .NET and Python: how snapshots work, how to enable SnapStart, and how to
  keep your code snap-safe.
- [The Feature You Must Know About If You're Using Lambda SnapStart for .NET](https://www.youtube.com/watch?v=c68hefro7TE)
  (James Eastham, YouTube, 16 min). Why ASP.NET Core cold starts stay high
  with SnapStart on, and the pre-warming feature that fixes it.

## Tools

- [AWS Lambda Power Tuning](https://github.com/alexcasalboni/aws-lambda-power-tuning)
  (GitHub). Finds the memory setting with the best cost or speed for a
  function. `bench/Start-PowerTuning.ps1` runs it against each variant.

## In this repo

- [Library Compatibility Matrix](Library-Compatibility-Matrix.md).
  Whether common .NET libraries work with Native AOT and SnapStart. Check
  your dependencies before you start.
- [Modernization Patterns](Modernization-Patterns.md).
  Steps for applying SnapStart priming, Native AOT and single-purpose
  functions to your own projects.
