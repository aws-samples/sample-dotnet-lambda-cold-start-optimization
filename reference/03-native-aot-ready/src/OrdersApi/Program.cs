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

// Use the source-generated context for results the framework serializes, such as Results.BadRequest
builder.Services.ConfigureHttpJsonOptions(options =>
    options.SerializerOptions.TypeInfoResolverChain.Insert(0, AppJsonContext.Default));

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

// Source-generated JSON serialization — use JsonTypeInfo overloads for AOT safety.
app.MapPost("/orders", async (HttpContext context, IOrderService orderService) =>
{
    Logger.LogInformation("Processing order request");

    try
    {
        var request = await JsonSerializer.DeserializeAsync(
            context.Request.Body, AppJsonContext.Default.OrderRequest);

        if (request is null)
            return Results.BadRequest("Invalid request body.");

        var response = await orderService.CreateOrderAsync(request);
        Logger.LogInformation("Order created: {orderId}", response.OrderId);
        var json = JsonSerializer.Serialize(response, AppJsonContext.Default.OrderResponse);
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
