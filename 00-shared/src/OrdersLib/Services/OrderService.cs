// Copyright © 2026 Amazon.com and Affiliates. Licensed under MIT-0.

using OrdersApi.Models;

namespace OrdersApi.Services;

public class OrderService : IOrderService
{
    private readonly IOrderValidator _validator;
    private readonly IOrderRepository _repository;

    public OrderService(
        IOrderValidator validator,
        IOrderRepository repository)
    {
        _validator = validator;
        _repository = repository;
    }

    public async Task<OrderResponse> CreateOrderAsync(OrderRequest request)
    {
        var (isValid, error) = _validator.Validate(request);
        if (!isValid)
            throw new ArgumentException(error);

        var order = new OrderResponse(
            OrderId: Guid.NewGuid().ToString(),
            CustomerId: request.CustomerId,
            ProductId: request.ProductId,
            Quantity: request.Quantity,
            Status: OrderStatus.Pending,
            CreatedAt: DateTime.UtcNow);

        return await _repository.SaveOrderAsync(order);
    }
}
