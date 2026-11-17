// Copyright © 2026 Amazon.com and Affiliates. Licensed under MIT-0.

using System.Diagnostics.CodeAnalysis;
using Amazon.DynamoDBv2;
using Amazon.DynamoDBv2.Model;
using OrdersApi.Models;

namespace OrdersApi.Services;

// FIX #3: Trimming annotations that resolve the AWS SDK IL2xxx warnings.
// Diff against OrderRepository.cs — that difference is the entire fix.
public class OrderRepositoryAot : IOrderRepository
{
    private readonly IAmazonDynamoDB _dynamoDb;
    private static readonly string TableName =
        Environment.GetEnvironmentVariable("ORDERS_TABLE_NAME") ?? "Orders";

    public OrderRepositoryAot(IAmazonDynamoDB dynamoDb)
    {
        _dynamoDb = dynamoDb;
    }

    [DynamicDependency(DynamicallyAccessedMemberTypes.All, typeof(PutItemRequest))]
    [DynamicDependency(DynamicallyAccessedMemberTypes.All, typeof(PutItemResponse))]
    [DynamicDependency(DynamicallyAccessedMemberTypes.All, typeof(AttributeValue))]
    [UnconditionalSuppressMessage("AOT", "IL2026",
        Justification = "AWS SDK DynamoDB low-level API is verified safe at runtime")]
    [UnconditionalSuppressMessage("AOT", "IL3050",
        Justification = "AWS SDK DynamoDB low-level API is verified safe at runtime")]
    public async Task<OrderResponse> SaveOrderAsync(OrderResponse order)
    {
        var item = new Dictionary<string, AttributeValue>
        {
            ["OrderId"] = new AttributeValue { S = order.OrderId },
            ["CustomerId"] = new AttributeValue { S = order.CustomerId },
            ["ProductId"] = new AttributeValue { S = order.ProductId },
            ["Quantity"] = new AttributeValue { N = order.Quantity.ToString() },
            ["Status"] = new AttributeValue { S = order.Status.ToString() },
            ["CreatedAt"] = new AttributeValue { S = order.CreatedAt.ToString("o") }
        };

        await _dynamoDb.PutItemAsync(new PutItemRequest
        {
            TableName = TableName,
            Item = item
        });

        return order;
    }
}
