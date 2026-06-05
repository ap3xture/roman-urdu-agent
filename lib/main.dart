import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'agent_controller.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
  ));
  runApp(const RomanUrduApp());
}

class RomanUrduApp extends StatelessWidget {
  const RomanUrduApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Roman Urdu Agent',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF080808),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF00D4AA),
          surface: Color(0xFF111111),
        ),
      ),
      home: const AgentScreen(),
    );
  }
}

class AgentScreen extends StatefulWidget {
  const AgentScreen({super.key});

  @override
  State<AgentScreen> createState() => _AgentScreenState();
}

class _AgentScreenState extends State<AgentScreen>
    with SingleTickerProviderStateMixin {
  final AgentController _controller = AgentController();
  final TextEditingController _textCtrl = TextEditingController();
  final ScrollController _scrollCtrl = ScrollController();

  String _transcript = '';
  String _response = '';
  bool _isListening = false;
  bool _isThinking = false;
  String _statusLabel = 'Tap mic to speak';

  late AnimationController _pulseCtrl;
  late Animation<double> _pulse;

  @override
  void initState() {
    super.initState();
    _controller.init();
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    )..repeat(reverse: true);
    _pulse = Tween<double>(begin: 1.0, end: 1.22).animate(
      CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _pulseCtrl.dispose();
    _controller.dispose();
    _textCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  // ─── STT ───────────────────────────────────────────────────────────────────

  Future<void> _toggleListen() async {
    if (_isListening) {
      await _controller.stopListening();
      setState(() {
        _isListening = false;
        _statusLabel = 'Tap mic to speak';
      });
      return;
    }

    setState(() {
      _isListening = true;
      _transcript = '';
      _response = '';
      _statusLabel = 'Sun raha hoon...';
    });

    await _controller.startListening(
      onTranscript: (text) => setState(() => _transcript = text),
      onDone: (final_) async {
        setState(() {
          _isListening = false;
          _transcript = final_;
          _statusLabel = 'Samajh raha hoon...';
        });
        await _runCommand(final_);
      },
    );
  }

  // ─── Text submit ───────────────────────────────────────────────────────────

  Future<void> _submitText() async {
    final text = _textCtrl.text.trim();
    if (text.isEmpty) return;
    _textCtrl.clear();
    FocusScope.of(context).unfocus();
    setState(() {
      _transcript = text;
      _response = '';
      _statusLabel = 'Samajh raha hoon...';
    });
    await _runCommand(text);
  }

  // ─── Core pipeline ─────────────────────────────────────────────────────────

  Future<void> _runCommand(String text) async {
    setState(() => _isThinking = true);
    final result = await _controller.processCommand(text);
    setState(() {
      _response = result;
      _isThinking = false;
      _statusLabel = 'Tap mic to speak';
    });
    _scrollToBottom();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(
          _scrollCtrl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  // ─── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: true,
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(),
            Expanded(child: _buildTranscriptArea()),
            _buildInputRow(),
            _buildMicButton(),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 36, 28, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'ASSISTANT',
            style: TextStyle(
              color: Color(0xFF00D4AA),
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 4,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'Roman Urdu\nTask Agent',
            style: TextStyle(
              color: Colors.white,
              fontSize: 26,
              fontWeight: FontWeight.w200,
              height: 1.3,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 24),
          Container(height: 1, color: Colors.white.withOpacity(0.06)),
        ],
      ),
    );
  }

  Widget _buildTranscriptArea() {
    return ListView(
      controller: _scrollCtrl,
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
      children: [
        // Empty state — capability infographic
        if (_transcript.isEmpty && _response.isEmpty)
          const _CapabilityGrid(),

        // User transcript
        if (_transcript.isNotEmpty) ...[
          _SpeakerLabel(label: 'YOU'),
          const SizedBox(height: 8),
          Text(
            _transcript,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 19,
              fontWeight: FontWeight.w300,
              height: 1.55,
            ),
          ),
          const SizedBox(height: 32),
        ],

        // Agent response / thinking
        if (_isThinking) ...[
          _SpeakerLabel(label: 'AGENT'),
          const SizedBox(height: 12),
          const _ThinkingDots(),
        ] else if (_response.isNotEmpty) ...[
          _SpeakerLabel(label: 'AGENT'),
          const SizedBox(height: 8),
          Text(
            _response,
            style: const TextStyle(
              color: Color(0xFF00D4AA),
              fontSize: 19,
              fontWeight: FontWeight.w300,
              height: 1.55,
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildInputRow() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 0, 28, 8),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _textCtrl,
              style: const TextStyle(color: Colors.white70, fontSize: 15),
              cursorColor: const Color(0xFF00D4AA),
              decoration: InputDecoration(
                hintText: 'Ya yahan likhein...',
                hintStyle: TextStyle(
                    color: Colors.white.withOpacity(0.18), fontSize: 15),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: Colors.white.withOpacity(0.08)),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: Colors.white.withOpacity(0.08)),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(
                      color: Color(0xFF00D4AA), width: 1.2),
                ),
                filled: true,
                fillColor: const Color(0xFF111111),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                isDense: true,
              ),
              onSubmitted: (_) => _submitText(),
              textInputAction: TextInputAction.send,
            ),
          ),
          const SizedBox(width: 10),
          GestureDetector(
            onTap: _submitText,
            child: Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                color: const Color(0xFF111111),
                border: Border.all(
                    color: Colors.white.withOpacity(0.08), width: 1),
              ),
              child: const Icon(Icons.arrow_upward,
                  color: Color(0xFF00D4AA), size: 18),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMicButton() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 36, top: 8),
      child: Column(
        children: [
          GestureDetector(
            onTap: _toggleListen,
            child: AnimatedBuilder(
              animation: _pulse,
              builder: (_, child) => Transform.scale(
                scale: _isListening ? _pulse.value : 1.0,
                child: child,
              ),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 250),
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _isListening
                      ? const Color(0xFF00D4AA)
                      : const Color(0xFF111111),
                  border: Border.all(
                    color: _isListening
                        ? const Color(0xFF00D4AA)
                        : Colors.white.withOpacity(0.15),
                    width: 1.5,
                  ),
                  boxShadow: _isListening
                      ? [
                          BoxShadow(
                            color: const Color(0xFF00D4AA).withOpacity(0.35),
                            blurRadius: 24,
                            spreadRadius: 4,
                          )
                        ]
                      : [],
                ),
                child: Icon(
                  _isListening ? Icons.stop_rounded : Icons.mic_none_rounded,
                  color: _isListening ? Colors.black : const Color(0xFF00D4AA),
                  size: 30,
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            _statusLabel,
            style: TextStyle(
              color: Colors.white.withOpacity(0.25),
              fontSize: 11,
              letterSpacing: 1.2,
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Small widgets ─────────────────────────────────────────────────────────────

class _SpeakerLabel extends StatelessWidget {
  final String label;
  const _SpeakerLabel({required this.label});

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: TextStyle(
        color: Colors.white.withOpacity(0.22),
        fontSize: 10,
        fontWeight: FontWeight.w700,
        letterSpacing: 3,
      ),
    );
  }
}

// ─── Capability infographic ────────────────────────────────────────────────────

class _CapabilityGrid extends StatelessWidget {
  const _CapabilityGrid();

  static const _caps = [
    _Cap(Icons.alarm,            'Alarm',       'saat baje alarm lagao',          0xFF4CAF50),
    _Cap(Icons.calendar_today,   'Reminder',    '5 baje meeting ka reminder',     0xFF2196F3),
    _Cap(Icons.timer,            'Timer',       '30 minute ka timer lagao',       0xFFFF9800),
    _Cap(Icons.call,             'Phone Call',  '0300... pe call karo',           0xFF9C27B0),
    _Cap(Icons.chat,             'WhatsApp',    'WhatsApp pe salam bhejo',        0xFF25D366),
    _Cap(Icons.map,              'Navigation',  'Lahore ka rasta dikhao',         0xFFE91E63),
    _Cap(Icons.search,           'Web Search',  'cricket score search karo',      0xFF03A9F4),
    _Cap(Icons.play_circle,      'YouTube',     'Atif Aslam ka gana lagao',       0xFFFF0000),
    _Cap(Icons.camera_alt,       'Camera',      'camera kholo ya selfie lo',      0xFF607D8B),
    _Cap(Icons.settings,         'Settings',    'WiFi ya Bluetooth settings',     0xFF795548),
    _Cap(Icons.bolt,             'Real-time',   'battery kitni hai? / time?',     0xFFFFEB3B),
    _Cap(Icons.auto_awesome,     'Ask Anything','Pakistan ki capital kya hai?',   0xFF00D4AA),
  ];

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 8),

        // Section label
        Text(
          'YEH KAR SAKTA HOON',
          style: TextStyle(
            color: Colors.white.withOpacity(0.22),
            fontSize: 10,
            fontWeight: FontWeight.w700,
            letterSpacing: 3,
          ),
        ),
        const SizedBox(height: 16),

        // 2-column grid
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: _caps.length,
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            crossAxisSpacing: 10,
            mainAxisSpacing: 10,
            childAspectRatio: 1.55,
          ),
          itemBuilder: (_, i) => _CapCard(cap: _caps[i]),
        ),

        const SizedBox(height: 24),

        // Bottom hint
        Center(
          child: Text(
            'Mic dabayein ya likhein',
            style: TextStyle(
              color: Colors.white.withOpacity(0.15),
              fontSize: 12,
              letterSpacing: 1,
            ),
          ),
        ),
        const SizedBox(height: 8),
      ],
    );
  }
}

class _Cap {
  final IconData icon;
  final String title;
  final String example;
  final int color;
  const _Cap(this.icon, this.title, this.example, this.color);
}

class _CapCard extends StatelessWidget {
  final _Cap cap;
  const _CapCard({required this.cap});

  @override
  Widget build(BuildContext context) {
    final accent = Color(cap.color);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF111111),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: accent.withOpacity(0.18), width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Icon + title row
          Row(
            children: [
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: accent.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(7),
                ),
                child: Icon(cap.icon, color: accent, size: 15),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  cap.title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const Spacer(),
          // Example command
          Text(
            '"${cap.example}"',
            style: TextStyle(
              color: Colors.white.withOpacity(0.35),
              fontSize: 10,
              fontStyle: FontStyle.italic,
              height: 1.4,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

// ─── Thinking dots ────────────────────────────────────────────────────────────

class _ThinkingDots extends StatefulWidget {
  const _ThinkingDots();

  @override
  State<_ThinkingDots> createState() => _ThinkingDotsState();
}

class _ThinkingDotsState extends State<_ThinkingDots>
    with SingleTickerProviderStateMixin {
  late AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (_, __) {
        return Row(
          children: List.generate(3, (i) {
            final phase = (_c.value + i / 3.0) % 1.0;
            final alpha = phase < 0.5 ? 1.0 : 0.2;
            return Container(
              margin: const EdgeInsets.only(right: 6),
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFF00D4AA).withOpacity(alpha),
              ),
            );
          }),
        );
      },
    );
  }
}
