// Demo controls shared by every component demo: a segmented control with a
// sliding thumb, pill buttons and colour swatches. Each demo keeps its own copy.
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

const kTrack = Color(0xFF1C1C20);
const kThumb = Color(0xFF3A3A40);
const kControlMuted = Color(0xFFA1A1AA);
const _disabledBg = Color(0xFF26262A);
const _disabledFg = Color(0xFF71717A);

/// Slider and switch colours to match the controls below.
ThemeData demoControlsTheme(ThemeData base) => base.copyWith(
  sliderTheme: const SliderThemeData(
    activeTrackColor: Colors.white,
    inactiveTrackColor: kTrack,
    thumbColor: Colors.white,
    overlayColor: Color(0x14FFFFFF),
    trackHeight: 4,
  ),
);

/// An iOS-style segmented control. The thumb slides to the selected segment;
/// with no selection it hides, which suits segments that are actions.
class Segmented<T> extends StatelessWidget {
  const Segmented({super.key, required this.segments, required this.selected, required this.onChanged, this.expand = false});

  final Map<T, String> segments;
  final T? selected;
  final ValueChanged<T>? onChanged;

  /// Fill the available width instead of sizing to the longest label.
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final keys = segments.keys.toList();
    final index = selected == null ? -1 : keys.indexOf(selected as T);
    final enabled = onChanged != null;
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final x = keys.length < 2 ? 0.0 : -1 + 2 * (index < 0 ? 0 : index) / (keys.length - 1);

    Widget control = Container(
      height: 40,
      padding: const EdgeInsets.all(3),
      decoration: const ShapeDecoration(color: kTrack, shape: StadiumBorder()),
      child: Stack(
        children: [
          AnimatedAlign(
            alignment: Alignment(x, 0),
            duration: reduceMotion ? Duration.zero : const Duration(milliseconds: 260),
            curve: Curves.easeOutCubic,
            child: FractionallySizedBox(
              widthFactor: 1 / keys.length,
              heightFactor: 1,
              child: AnimatedOpacity(
                opacity: index < 0 ? 0 : 1,
                duration: const Duration(milliseconds: 160),
                child: const DecoratedBox(decoration: ShapeDecoration(color: kThumb, shape: StadiumBorder())),
              ),
            ),
          ),
          Row(
            children: [
              for (final (i, key) in keys.indexed)
                Expanded(
                  child: Semantics(
                    button: true,
                    selected: i == index,
                    enabled: enabled,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: enabled ? () => onChanged!(key) : null,
                      child: Center(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 14),
                          child: AnimatedDefaultTextStyle(
                            duration: const Duration(milliseconds: 160),
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: !enabled ? _disabledFg : (i == index ? Colors.white : kControlMuted),
                            ),
                            child: Text(segments[key]!, maxLines: 1),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
    if (!expand) control = IntrinsicWidth(child: control);
    return control;
  }
}

/// A pill button: white when [primary], a dark glass pill otherwise.
class PillButton extends StatelessWidget {
  const PillButton({super.key, required this.label, required this.onPressed, this.primary = false, this.expand = false});

  final String label;
  final VoidCallback? onPressed;
  final bool primary;
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final button = FilledButton(
      onPressed: onPressed,
      style: FilledButton.styleFrom(
        backgroundColor: primary ? Colors.white : kTrack,
        foregroundColor: primary ? const Color(0xFF0B0B0D) : Colors.white,
        disabledBackgroundColor: _disabledBg,
        disabledForegroundColor: _disabledFg,
        shape: const StadiumBorder(),
        minimumSize: const Size(0, 44),
        padding: const EdgeInsets.symmetric(horizontal: 20),
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
      ),
      child: Text(label),
    );
    return expand ? SizedBox(width: double.infinity, child: button) : button;
  }
}

/// A row of colour dots. Each swatch is one colour or a two-colour blend.
class Swatches extends StatelessWidget {
  const Swatches({super.key, required this.swatches, required this.selected, required this.onChanged});

  /// Name → one or two colours.
  final Map<String, List<Color>> swatches;
  final String selected;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 14,
      alignment: WrapAlignment.center,
      children: [
        for (final MapEntry(key: name, value: colors) in swatches.entries)
          Semantics(
            button: true,
            selected: name == selected,
            label: name,
            child: GestureDetector(
              onTap: () => onChanged(name),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                width: 30,
                height: 30,
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: name == selected ? Colors.white : Colors.transparent, width: 2),
                ),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: colors.length == 1 ? [colors.first, colors.first] : colors,
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// An iOS-style switch in the demo colours.
class DemoSwitch extends StatelessWidget {
  const DemoSwitch({super.key, required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) =>
      CupertinoSwitch(value: value, onChanged: onChanged, activeTrackColor: const Color(0xFF34C759), inactiveTrackColor: kThumb);
}
