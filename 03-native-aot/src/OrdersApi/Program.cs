// Copyright © 2026 Amazon.com and Affiliates. Licensed under MIT-0.

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
