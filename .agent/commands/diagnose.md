Hãy chạy chẩn đoán toàn diện các session và nhật ký lỗi gần đây của mini-agent:

1. Đọc các file journal mới nhất trong thư mục `~/.mini/sessions/journal_*.jsonl`.
2. Liệt kê các lỗi backend (4xx, 5xx, rate-limit, 529), lỗi parse SSE, hoặc các Act bị gián đoạn/abort.
3. Tóm tắt nguyên nhân của các lỗi gần nhất và đề xuất cách khắc phục hoặc cấu hình cần điều chỉnh.
