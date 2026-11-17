// Copyright © 2026 Amazon.com and Affiliates. Licensed under MIT-0.

using System.Diagnostics;
using System.Text.Json;
using Amazon.DynamoDBv2;
using AWS.Lambda.Powertools.Logging;
using OrdersApi.Models;
using OrdersApi.Services;

var builder = WebApplication.CreateBuilder(args);

// Add AWS Lambda hosting
builder.Services.AddAWSLambdaHosting(LambdaEventSource.RestApi);

// Add Powertools structured logging (captures cold start, function name, memory, etc.)
builder.Logging.ClearProviders();
builder.Logging.AddPowertoolsLogger();

// Add AWS SDK
builder.Services.AddSingleton(typeof(IAmazonDynamoDB), typeof(AmazonDynamoDBClient));
builder.Services.AddSingleton(typeof(IOrderValidator), typeof(OrderValidator));
builder.Services.AddSingleton(typeof(IOrderService), typeof(OrderService));
builder.Services.AddSingleton(typeof(IOrderRepository), typeof(OrderRepository));

var app = builder.Build();

var jsonOptions = new JsonSerializerOptions
{
    PropertyNameCaseInsensitive = true
};

app.MapPost("/orders", async (HttpContext context, IOrderService orderService) =>
{
    var handlerStart = Stopwatch.GetTimestamp();
    Logger.LogInformation("Processing order request");

    var request = await JsonSerializer.DeserializeAsync<OrderRequest>(
        context.Request.Body, jsonOptions);

    if (request is null)
        return Results.BadRequest("Invalid request body.");

    try
    {
        var serviceStart = Stopwatch.GetTimestamp();
        var response = await orderService.CreateOrderAsync(request);
        var serviceMs = Stopwatch.GetElapsedTime(serviceStart).TotalMilliseconds;

        var json = JsonSerializer.Serialize(response, jsonOptions);

        Logger.LogInformation(
            "Order created: {orderId} (service {serviceMs} ms, handler {handlerMs} ms)",
            response.OrderId, serviceMs,
            Stopwatch.GetElapsedTime(handlerStart).TotalMilliseconds);

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
