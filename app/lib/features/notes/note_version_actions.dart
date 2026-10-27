import 'package:flutter/material.dart';

/// Identical choice wording and pending behavior on Windows and Android.
class NoteVersionActions extends StatelessWidget {
  const NoteVersionActions(
      {super.key,
      required this.phoneHash,
      required this.computerHash,
      required this.busy,
      required this.onChoose,
      this.pending,
      this.batch = false});
  final String? phoneHash, computerHash;
  final bool busy;
  final Map<String, dynamic>? pending;
  final ValueChanged<String> onChoose;
  final bool batch;

  @override
  Widget build(BuildContext context) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (pending != null)
          Text(
              '已选择${pending!['source'] == 'phone' ? '手机版' : '电脑版'}，等待手机连接并打开 APP 执行。'),
        Wrap(spacing: 8, runSpacing: 8, children: [
          OutlinedButton.icon(
              onPressed: busy || pending != null || phoneHash == null
                  ? null
                  : () => onChoose('phone'),
              icon: const Icon(Icons.phone_android),
              label: Text(batch ? '全部同步手机的笔记' : '同步手机的笔记')),
          OutlinedButton.icon(
              onPressed: busy || pending != null || computerHash == null
                  ? null
                  : () => onChoose('computer'),
              icon: const Icon(Icons.computer),
              label: Text(batch ? '全部同步电脑的笔记' : '同步电脑的笔记')),
        ]),
        Text(
            batch
                ? '只处理所选来源存在的差异笔记；不会删除另一端独有的文件。'
                : phoneHash == null
                    ? '手机没有这篇笔记，可将电脑版同步到手机。'
                    : computerHash == null
                        ? '电脑没有这篇笔记，可将手机版同步到电脑。'
                        : '采用所选版本覆盖另一端，成功后不保留被替换版本。',
            style: Theme.of(context).textTheme.bodySmall),
      ]);
}
