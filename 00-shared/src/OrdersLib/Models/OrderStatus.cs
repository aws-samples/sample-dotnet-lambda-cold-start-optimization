// Copyright © 2026 Amazon.com and Affiliates. Licensed under MIT-0.

using System.Text.Json.Serialization;
namespace OrdersApi.Models;

// Serialized by name ("Pending") rather than number. The generic converter
// works with both reflection and source-generated serialization.
[JsonConverter(typeof(JsonStringEnumConverter<OrderStatus>))]
public enum OrderStatus
{
    Pending,
    Confirmed,
    Shipped
}
