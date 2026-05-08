import 'package:flutter/material.dart';
import '../core/player.dart';
import '../core/theme.dart';

void showQueueSheet(BuildContext context, ShamlssPlayer player) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: ShamlssColors.card,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
    builder: (_) => _QueueSheet(player: player),
  );
}

class _QueueSheet extends StatefulWidget {
  final ShamlssPlayer player;
  const _QueueSheet({required this.player});

  @override
  State<_QueueSheet> createState() => _QueueSheetState();
}

class _QueueSheetState extends State<_QueueSheet> {
  ShamlssPlayer get player => widget.player;

  @override
  Widget build(BuildContext context) {
    final maxH = MediaQuery.of(context).size.height * 0.75;
    return ListenableBuilder(
      listenable: player,
      builder: (context, _) {
        final queue = player.queue;
        final current = player.index;
        return SizedBox(
          height: maxH,
          child: Column(children: [
            const SizedBox(height: 8),
            Container(width: 36, height: 4, decoration: BoxDecoration(color: ShamlssColors.divider, borderRadius: BorderRadius.circular(2))),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(children: [
                const Text('QUEUE', style: TextStyle(color: ShamlssColors.amberDim, fontSize: 12, letterSpacing: 2)),
                const SizedBox(width: 8),
                Text('${queue.length} tracks', style: const TextStyle(color: ShamlssColors.divider, fontSize: 11)),
                const Spacer(),
                TextButton(
                  onPressed: queue.isEmpty ? null : () {
                    // Clear all except current
                    for (int i = queue.length - 1; i >= 0; i--) {
                      if (i != current) player.removeFromQueue(i);
                    }
                  },
                  child: const Text('Clear', style: TextStyle(color: ShamlssColors.textMuted, fontSize: 12)),
                ),
              ]),
            ),
            const Divider(height: 1, color: ShamlssColors.divider),
            Expanded(
              child: queue.isEmpty
                  ? const Center(child: Text('Queue is empty', style: TextStyle(color: ShamlssColors.textMuted)))
                  : ReorderableListView.builder(
                      padding: EdgeInsets.zero,
                      itemCount: queue.length,
                      onReorder: (from, to) {
                        if (to > from) to--;
                        player.moveInQueue(from, to);
                      },
                      itemBuilder: (_, i) {
                        final t = queue[i];
                        final isCurrent = i == current;
                        return Dismissible(
                          key: ValueKey('$i-${t['id']}'),
                          direction: DismissDirection.endToStart,
                          background: Container(
                            alignment: Alignment.centerRight,
                            color: Colors.red.withOpacity(0.2),
                            padding: const EdgeInsets.only(right: 20),
                            child: const Icon(Icons.delete_outline, color: Colors.red, size: 20),
                          ),
                          onDismissed: (_) => player.removeFromQueue(i),
                          child: ListTile(
                            dense: true,
                            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
                            leading: isCurrent
                                ? const Icon(Icons.graphic_eq, color: ShamlssColors.amber, size: 18)
                                : Text('${i + 1}', style: const TextStyle(color: ShamlssColors.divider, fontSize: 11)),
                            title: Text(
                              t['title'] ?? 'Unknown',
                              style: TextStyle(
                                color: isCurrent ? ShamlssColors.amber : ShamlssColors.text,
                                fontSize: 13,
                                fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: t['artist'] != null
                                ? Text(t['artist'] as String, style: const TextStyle(color: ShamlssColors.textMuted, fontSize: 11), overflow: TextOverflow.ellipsis)
                                : null,
                            onTap: () => player.jumpTo(i),
                            trailing: ReorderableDragStartListener(
                              index: i,
                              child: const Icon(Icons.drag_handle, color: ShamlssColors.divider, size: 20),
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ]),
        );
      },
    );
  }
}
