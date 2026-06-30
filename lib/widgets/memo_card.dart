import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../models/memo.dart';
import 'category_chip.dart';

class MemoCard extends StatelessWidget {
  final Memo memo;
  final VoidCallback? onTap;
  final VoidCallback? onDelete;

  const MemoCard({
    super.key,
    required this.memo,
    this.onTap,
    this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final dateFormat = DateFormat('yyyy.MM.dd HH:mm');

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      elevation: 1,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Top row: category chip + date
              Row(
                children: [
                  CategoryChip(category: memo.category),
                  const SizedBox(width: 8),
                  Text(
                    dateFormat.format(memo.createdAt),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Colors.grey[500],
                        ),
                  ),
                  const Spacer(),
                  if (memo.sourceUrl != null)
                    Icon(Icons.link, size: 16, color: Colors.grey[400]),
                  if (memo.youtubeVideoId != null) ...[
                    const SizedBox(width: 4),
                    Icon(Icons.play_circle_outline,
                        size: 16, color: Colors.red[300]),
                  ],
                  if (onDelete != null)
                    IconButton(
                      icon: Icon(Icons.delete_outline,
                          size: 18, color: Colors.grey[400]),
                      onPressed: onDelete,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      splashRadius: 16,
                    ),
                ],
              ),
              const SizedBox(height: 8),
              // Title
              Text(
                memo.title,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 4),
              // Content preview
              Text(
                memo.content,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Colors.grey[600],
                    ),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
