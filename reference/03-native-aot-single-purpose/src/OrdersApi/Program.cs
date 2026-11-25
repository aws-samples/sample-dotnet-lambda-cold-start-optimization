// Copyright © 2026 Amazon.com and Affiliates. Licensed under MIT-0.

using System.Text.Json;
using Amazon.DynamoDBv2;
using Amazon.Lambda.APIGatewayEvents;
using Amazon.Lambda.Core;
using Amazon.Lambda.RuntimeSupport;
using Amazon.Lambda.Serialization.SystemTextJson;
using Microsoft.Extensions.DependencyInjection;
using OrdersApi;
using OrdersApi.Models;
using OrdersApi.Services;

// Single purpose: one function, one route. API Gateway's event goes straight
// to the handler — no ASP.NET Core host, no Powertools. 03-native-aot-ready
// does the same work through both.
ServiceCollection services = new();
services.AddSingleton<IAmazonDynamoDB, AmazonDynamoDBClient>();
services.AddSingleton<IOrderValidator, OrderValidator>();
services.AddSingleton<IOrderRepository, OrderRepository>();
services.AddSingleton<IOrderService, OrderService>();

// Resolved during init, so the DynamoDB client is built before the first
// request rather than inside it.
IOrderService orderService = services.BuildServiceProvider()
    .GetRequiredService<IOrderService>();

async Task<APIGatewayProxyResponse> CreateOrderAsync(
    APIGatewayProxyRequest request, ILambdaContext context)
{
    try
    {
        OrderRequest? order = JsonSerializer.Deserialize(
            request.Body ?? "", AppJsonContext.Default.OrderRequest);
        if (order is null)
            return Error("Invalid request body.");

        OrderResponse response = await orderService.CreateOrderAsync(order);
        return Respond(200, JsonSerializer.Serialize(
            response, AppJsonContext.Default.OrderResponse));
    }
    catch (JsonException)
    {
        return Error("Invalid request body.");
    }
    catch (ArgumentException ex)
    {
        return Error(ex.Message);
    }
}

// Every response is JSON, so error messages match the ASP.NET Core variants.
static APIGatewayProxyResponse Respond(int statusCode, string json) => new()
{
    StatusCode = statusCode,
    Body = json,
    Headers = new Dictionary<string, string> { ["Content-Type"] = "application/json; charset=utf-8" }
};

static APIGatewayProxyResponse Error(string message) =>
    Respond(400, JsonSerializer.Serialize(message, AppJsonContext.Default.String));

await LambdaBootstrapBuilder
    .Create<APIGatewayProxyRequest, APIGatewayProxyResponse>(
        CreateOrderAsync,
        new SourceGeneratorLambdaJsonSerializer<AppJsonContext>())
    .Build()
    .RunAsync();
