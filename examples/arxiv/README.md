# 📚 ArXiv Paper Aggregator

Một trợ lý Agent dựa trên năng lực của `mini-agent` phục vụ việc truy vấn, chắt lọc và tóm tắt những bài báo khoa học đỉnh cao mang tính đột phá trên trang chủ arXiv, tập trung sâu vào lĩnh vực Khoa Học Máy Tính (AI, LLM, Computer Vision, Networking...).

Hệ thống có thể trích xuất Atom XML format tự động thông qua Python script do Agent tự tay sinh ra, sau đó xuất báo cáo dưới dạng Markdown. Định dạng báo cáo được thiết kế cho Software Engineers dễ dàng grasp được các ý chính của paper trong \`TL;DR\`.

## 🚀 Cách cài đặt nhanh

```bash
cd examples/arxiv
./run.sh
```

## ⚙️ Tùy chọn nâng cao

Bạn có thể chỉnh sửa số lượng bài viết (tối đa lấy về từ API) và đổi vị trí file output như sau:

```bash
./run.sh --max-results 30 --output /tmp/my_arxiv_digest.md
```

## 🧠 Model yêu cầu
Agent sẽ yêu cầu năng lực logic rất mạnh và Context window lớn để xử lý nội dung tóm tắt Paper. Khuyên dùng:
- `gpt-4o`
- `claude-3-5-sonnet`
- Mô hình lớn có khả năng Reasoning nếu bạn chạy qua OpenAI Comppatible backend.
