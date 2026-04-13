using MongoDB.Driver;
using FlashSaleMarketplace.Services; // Nhớ đổi tên namespace này cho đúng với project của bạn

var builder = WebApplication.CreateBuilder(args);

// 1. CHUYỂN ĐỔI SANG MÔ HÌNH CONTROLLER
// Template cũ dùng Minimal API, hệ thống của chúng ta dùng Controller nên cần khai báo dòng này
builder.Services.AddControllers();

// Cấu hình Swagger để test API giao diện Web
builder.Services.AddEndpointsApiExplorer();
builder.Services.AddSwaggerGen();

// =========================================================================
// 2. CẤU HÌNH KẾT NỐI MONGODB & INJECT DỊCH VỤ
// Lấy chuỗi kết nối từ file appsettings.json
var mongoConnectionString = builder.Configuration.GetSection("MongoDbSettings:ConnectionString").Value;
var mongoDbName = builder.Configuration.GetSection("MongoDbSettings:DatabaseName").Value;

// Đăng ký MongoClient (Dùng AddSingleton vì ứng dụng chỉ cần 1 Connection Pool duy nhất)
builder.Services.AddSingleton<IMongoClient>(new MongoClient(mongoConnectionString));

// Đăng ký Database context
builder.Services.AddScoped<IMongoDatabase>(sp => 
{
    var client = sp.GetRequiredService<IMongoClient>();
    return client.GetDatabase(mongoDbName);
});

// Đăng ký CartService để Controller có thể gọi ra dùng
builder.Services.AddScoped<CartService>();
// =========================================================================

var app = builder.Build();

// Configure the HTTP request pipeline.
if (app.Environment.IsDevelopment())
{
    app.UseSwagger();
    app.UseSwaggerUI();
}

app.UseHttpsRedirection();

// 3. MAP CONTROLLERS
// Báo cho .NET biết đường dẫn API sẽ được định tuyến vào các file trong thư mục Controllers
app.MapControllers();

app.Run();