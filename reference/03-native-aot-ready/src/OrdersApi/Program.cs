// Copyright © 2026 Amazon.com and Affiliates. Licensed under MIT-0.

using System.Text.Json;
using Amazon.DynamoDBv2;
using Amazon.Lambda.Serialization.SystemTextJson;
using AWS.Lambda.Powertools.Logging;
using OrdersApi;
using OrdersApi.Models;
using OrdersApi.Services;

var builder = WebApplication.CreateBuilder(args);

// Add AWS Lambda hosting — AOT-safe overload with source-generated serializer
builder.Services.AddAWSLambdaHosting(LambdaEventSource.RestApi,
    new SourceGeneratorLambdaJsonSerializer<AppJsonContext>());

// Add Powertools structured logging (captures cold start, function name, memory, etc.)
builder.Logging.ClearProviders();
builder.Logging.AddPowertoolsLogger();

// Add AWS SDK
builder.Services.AddSingleton<IAmazonDynamoDB, AmazonDynamoDBClient>();

// FIX #2: Explicit DI registration — compile-time visible to the trimmer.
builder.Services.AddSingleton<IOrderValidator, OrderValidator>();
builder.Services.AddSingleton<IOrderService, OrderService>();

// FIX #3: Point at the trim-annotated repository. The fix itself is in
// 00-shared/src/OrdersLib/Services/OrderRepositoryAot.cs — diff it against
// OrderRepository.cs beside it to see the five attributes that resolve IL2xxx.
builder.Services.AddSingleton<IOrderRepository, OrderRepositoryAot>();

var app = builder.Build();

// FIX #1: Source-generated JSON serialization — use JsonTypeInfo overloads for AOT safety.
app.MapPost("/orders", async (HttpContext context, IOrderService orderService) =>
{
    Logger.LogInformation("Processing order request");

    var request = await JsonSerializer.DeserializeAsync(
        context.Request.Body,
        AppJsonContext.Default.OrderRequest);

    if (request is null)
        return Results.BadRequest("Invalid request body.");

    try
    {
        var response = await orderService.CreateOrderAsync(request);
        Logger.LogInformation("Order created: {orderId}", response.OrderId);
        var json = JsonSerializer.Serialize(response, AppJsonContext.Default.OrderResponse);
        return Results.Content(json, "application/json", statusCode: 200);
    }
    catch (ArgumentException ex)
    {
        Logger.LogWarning("Validation failed: {error}", ex.Message);
        return Results.BadRequest(ex.Message);
    }
});

app.MapGet("/health", () => "Healthy");

app.Run();
