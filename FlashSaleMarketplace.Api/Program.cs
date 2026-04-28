using Microsoft.AspNetCore.RateLimiting;
using System.Threading.RateLimiting;
using Microsoft.EntityFrameworkCore;
using MongoDB.Driver;
using StackExchange.Redis; // THÊM DÒNG NÀY
using FlashSaleMarketplace.Api.Services; 

var builder = WebApplication.CreateBuilder(args);

// ==========================================
// 1. CẤU HÌNH SQL SERVER
// ==========================================
var sqlConnectionString = builder.Configuration.GetConnectionString("SqlServerConnection");

// ==========================================
// 2. CẤU HÌNH MONGODB
// ==========================================
var mongoConnectionString = builder.Configuration.GetConnectionString("MongoDbConnection");
var mongoDbName = builder.Configuration.GetSection("MongoDbSettings:DatabaseName").Value;

builder.Services.AddSingleton<IMongoClient>(new MongoClient(mongoConnectionString));
builder.Services.AddScoped<IMongoDatabase>(sp => 
{
    var client = sp.GetRequiredService<IMongoClient>();
    return client.GetDatabase(mongoDbName);
});

builder.Services.AddScoped<CartService>();

// ==========================================
// 2.5. CẤU HÌNH REDIS (Nâng cấp Phase 1 & 2)
// ==========================================
var redisConnectionString = builder.Configuration.GetConnectionString("RedisConnection");
// Dùng Singleton để dùng chung 1 Multiplexer cho toàn bộ ứng dụng (Tối ưu kết nối mạng)
builder.Services.AddSingleton<IConnectionMultiplexer>(ConnectionMultiplexer.Connect(redisConnectionString!));


// ==========================================
// 3. CẤU HÌNH API & SWAGGER
// ==========================================
builder.Services.AddControllers();
builder.Services.AddEndpointsApiExplorer();
builder.Services.AddSwaggerGen();
// [THÊM MỚI] Đăng ký RabbitMQ Producer
builder.Services.AddSingleton<FlashSaleMarketplace.Api.Messaging.RabbitMqProducer>();

// [THÊM MỚI] Đăng ký Công nhân chạy ngầm hút Queue
builder.Services.AddHostedService<FlashSaleMarketplace.Api.Workers.OrderProcessingWorker>();

// ==========================================
// 4. CẤU HÌNH RATE LIMITING (PHASE 4 - CHỐNG BOT THEO IP)
// ==========================================
builder.Services.AddRateLimiter(options =>
{
    options.RejectionStatusCode = 429;
    
    // Đổi từ AddFixedWindowLimiter (Toàn cục) sang AddPolicy (Phân vùng)
    options.AddPolicy("FlashSaleLimit", httpContext =>
    {
        // Tuyệt chiêu: Ưu tiên đọc IP giả lập từ JMeter (Header X-Real-IP)
        // Nếu không có (người dùng thật) thì đọc IP thật của máy
        var clientIp = httpContext.Request.Headers["X-Real-IP"].ToString();
        if (string.IsNullOrEmpty(clientIp))
        {
            clientIp = httpContext.Connection.RemoteIpAddress?.ToString() ?? "unknown";
        }

        // Tự động gom nhóm (Partition) các request theo từng IP
        return RateLimitPartition.GetFixedWindowLimiter(
            partitionKey: clientIp, 
            factory: partition => new FixedWindowRateLimiterOptions
            {
                PermitLimit = 5, // Mỗi IP khác nhau được phép gọi 5 lần / giây
                Window = TimeSpan.FromSeconds(1),
                QueueProcessingOrder = QueueProcessingOrder.OldestFirst,
                QueueLimit = 0
            });
    });
});

var app = builder.Build();



if (app.Environment.IsDevelopment())
{
    app.UseSwagger();
    app.UseSwaggerUI();
}

app.UseDefaultFiles();
app.UseStaticFiles();

app.UseHttpsRedirection();
app.UseAuthorization();
app.UseRateLimiter();
app.MapControllers();

app.Run();