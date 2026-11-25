// Copyright © 2026 Amazon.com and Affiliates. Licensed under MIT-0.

using System.Text.Json;
using Amazon.DynamoDBv2;
using AWS.Lambda.Powertools.Logging;
using OrdersApi.Models;
using OrdersApi.Services;

var builder = WebApplication.CreateBuilder(args);

// Add AWS Lambda hosting
builder.Services.AddAWSLambdaHosting(LambdaEventSource.RestApi);

// Add warm-up requests before snapshot (called 5 times)
builder.Services.AddAWSLambdaBeforeSnapshotRequest(new HttpRequestMessage(HttpMethod.Get, "/health"));
builder.Services.AddAWSLambdaBeforeSnapshotRequest(new HttpRequestMessage(HttpMethod.Post, "/orders")
{
    Content = JsonContent.Create(new OrderRequest("snapstart-warmup", "snapstart-warmup", 1))
});

// Add Powertools structured logging (captures cold start, function name, memory, etc.)
builder.Logging.ClearProviders();
builder.Logging.AddPowertoolsLogger();

// Add AWS SDK
builder.Services.AddSingleton<IAmazonDynamoDB, AmazonDynamoDBClient>();

// Add application services
builder.Services.AddSingleton<IOrderValidator, OrderValidator>();
builder.Services.AddSingleton<IOrderService, OrderService>();
builder.Services.AddSingleton<IOrderRepository, OrderRepository>();

var app = builder.Build();

var jsonOptions = new JsonSerializerOptions
{
    PropertyNameCaseInsensitive = true,
    PropertyNamingPolicy = JsonNamingPolicy.CamelCase
};

// SnapStart hook: runs before the snapshot is created.
Amazon.Lambda.Core.SnapshotRestore.RegisterBeforeSnapshot(async () =>
{
    using var scope = app.Services.CreateScope();
    var orderService = scope.ServiceProvider.GetRequiredService<IOrderService>();
    var warmupRequest = new OrderRequest("snapstart-warmup", "snapstart-warmup", 1);
    var warmupJson = JsonSerializer.SerializeToUtf8Bytes(warmupRequest, jsonOptions);
    for (var i = 1; i <= 5; i++)
    {
        using var stream = new MemoryStream(warmupJson);
        var request = (await JsonSerializer.DeserializeAsync<OrderRequest>(stream, jsonOptions))!;
        var response = await orderService.CreateOrderAsync(request);
        Logger.LogInformation("Priming pass {pass}: {orderId}", i, response.OrderId);
        _ = JsonSerializer.Serialize(response, jsonOptions);
    }
});

app.MapPost("/orders", async (HttpContext context, IOrderService orderService) =>
{
    Logger.LogInformation("Processing order request");

    try
    {
        var request = await JsonSerializer.DeserializeAsync<OrderRequest>(
            context.Request.Body, jsonOptions);

        if (request is null)
            return Results.BadRequest("Invalid request body.");

        var response = await orderService.CreateOrderAsync(request);
        Logger.LogInformation("Order created: {orderId}", response.OrderId);
        var json = JsonSerializer.Serialize(response, jsonOptions);
        return Results.Content(json, "application/json; charset=utf-8", statusCode: 200);
    }
    catch (JsonException)
    {
        return Results.BadRequest("Invalid request body.");
    }
    catch (ArgumentException ex)
    {
        Logger.LogWarning("Validation failed: {error}", ex.Message);
        return Results.BadRequest(ex.Message);
    }
});

app.MapGet("/health", () => "Healthy");

app.Run();