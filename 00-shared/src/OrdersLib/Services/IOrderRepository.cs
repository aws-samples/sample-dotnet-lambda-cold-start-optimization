// Copyright © 2026 Amazon.com and Affiliates. Licensed under MIT-0.

using OrdersApi.Models;

namespace OrdersApi.Services;

public interface IOrderRepository
{
    Task<OrderResponse> SaveOrderAsync(OrderResponse order);
}
