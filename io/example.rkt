#lang racket

;;; ============================================================================
;;; io/example.rkt —— 参考示例：用 core 的 api 拼一个真编辑器
;;; ============================================================================
;;;
;;; 目的：让你看清「core 提供什么机制 / 应用怎么组合 / 哪里是应用策略 / 哪里 core 缺东西」，
;;; 从而给 core 提出改进。
;;;
;;; 注释有固定标签，请按标签读：
;;;
;;;   [core]   用到的 core 能力（原子 / 文档 / 视口 / 编辑原语）
;;;   [意图]   为什么选这个 api、为什么这个顺序、保证什么不变量
;;;   [前端]   应用自己的策略，core 不该管（高亮、终端、按键映射、状态栏）
;;;
;;; 数据驱动：应用状态是一个不可变 struct `app`；命令都是 `app -> app` 的纯函数；
;;; 只有最外层事件循环用 set! 更新一次。core 的 editor 只是 app 的一个字段。
;;;
;;; core 的编辑只有**一个原语** `editor-command`（策略全是参数）：
;;;   editor-edit     = 焦点 view + #:reaction 'leader + #:record? #t   （用户编辑）
;;;   editor-view-edit= 指定 view + 同上
;;;   editor-command  = 本示例直接用它演示「程序编辑」：显式 #:selection + 默认 reaction 'none
;;;
;;; 运行：  racket io/example.rkt [文件]
;;; 按键：  可打印/中文 插入   Enter 自动缩进换行   Backspace/Delete 删除   Tab 两空格
;;;         ←→↑↓ Home End PgUp PgDn 导航   Shift+方向 扩选   Alt+↑↓ 上下加光标
;;;         ^D 选中下一个相同串（多光标）  ^A 选中全部相同串  Esc 回单光标/退出
;;;         ^Z 撤销  ^Y 重做  ^G 程序面追加时间戳  ^L 开关高亮  ^Q 退出

(require "../core/editor.rkt"
         ;; racket-tui 也导出 key-event/resize-event/cursor-col 等，与 core 同名；用 core 的。
         (except-in tui key-event key-event? key-event-key struct:key-event
                    resize-event resize-event? resize-event-rows resize-event-cols
                    struct:resize-event cursor-col)
         racket/file racket/string racket/path)

;;; ============================================================================
;;; §1 应用状态
;;; ============================================================================
;;
;; [core] core 只提供 `editor` 这一个不可变状态值；其余（终端尺寸、文件名、
;;        是否高亮）都是**前端状态**，core 不存。
;; [前端] 会话状态（比如「有没有未保存改动」）也归前端——core 的 tick 只是版本戳。

(struct app (ed rows cols name highlight?) #:transparent)
;; ed        : editor
;; rows/cols : nat      终端整屏尺寸（最后一行留作状态栏）
;; name      : string
;; highlight? : boolean 是否跑关键字高亮

(define (make-app text rows cols name)
  (app (editor-open text (max 1 (sub1 rows)) cols #:name name)
       rows cols name #t))

(define (open-app path rows cols)
  (make-app (if (and path (file-exists? path)) (file->string path) "")
            rows cols
            (if path (path->string (file-name-from-path path)) "*scratch*")))

;;; ============================================================================
;;; §2 组合操作（每条都标了 [core]/[意图]/[前端]）
;;; ============================================================================

;; 2.0 编辑：没有任何「重算」步骤
;; [core] editor-edit ed op → (values editor report)，用户编辑（leader + 记账）。
;;        文本变；派生 face 不存文档，所以不存在「过期」，也就没有重算。
;; [意图] 高亮走投影时的 face-provider（见 2.8 / §3），编辑路径与标注解耦。
;;
;; core 命令有两种返回形状：editor（视图命令）或 (values editor report)（编辑 / 账本）。
;; 这里只把 editor 塞回 app；report 前端不用。
(define (run-ed a f)
  (define-values (ed _report) (f (app-ed a)))
  (struct-copy app a [ed ed]))

;; 一次用户编辑：op : buffer selection → edit-desc。
(define (edit a op) (run-ed a (lambda (ed) (editor-edit ed op))))

;; 2.2 回车：自动缩进
;; [core] op 是**值**：`buffer selection -> edit-desc`。可以自己写，先看 buffer 再决定插什么。
;; [意图] 自动缩进 = 插 "\n" + 当前行前导空白，必须读 buffer，所以用自定义 op；
;;        edit-newline 只会插一个 "\n"，做不到。
;; [前端] 缩进宽度、是否缩进，是应用策略。
(define (newline app)
  (edit app
        (lambda (b sel)
          (define p (selection-head sel))
          (define line (buffer-line-ref b (point-line p)))
          (define indent (car (regexp-match #rx"^[ \t]*" line)))
          (edit-desc (selection-anchor sel) (selection-head sel) (string-append "\n" indent)))))

;; 2.3 导航
;; [core] editor-left/right/up/down/home/end/scroll（命名用户命令，内部走 editor-command 组合）。
;; [意图] 用户导航 = 动焦点光标 + 保证可见 + 同 buffer 的 follow 视图镜像。
;; [前端] 按键 → 动作的映射属于应用。
(define (navigate a sym)
  (define ed (app-ed a))
  (struct-copy app a
    [ed (case sym
          [(left)     (editor-left ed)]
          [(right)    (editor-right ed)]
          [(up)       (editor-up ed)]
          [(down)     (editor-down ed)]
          [(home)     (editor-home ed)]
          [(end)      (editor-end ed)]
          [(pageup)   (editor-scroll ed (- (editor-height ed)))]
          [(pagedown) (editor-scroll ed (editor-height ed))])]))

;; 2.5 程序编辑：不打扰用户
;; [core] editor-command 是唯一编辑原语；策略是参数。
;; [意图] 「在文件末尾追加时间戳」不该把用户光标拽走 —— 用显式 #:selection 指定位置，
;;        reaction 留默认 'none（不动任何视图），也不记账。
(define (append-stamp a)
  (define ed (app-ed a))
  (define bid (editor-buffer-id ed))
  (define n (editor-buffer-line-count ed bid))
  (define p (point (sub1 n) (editor-buffer-line-length ed bid (sub1 n))))
  (define stamp (number->string (current-seconds)))
  (define-values (ed* _report)
    (editor-command ed (edit-insert (string-append "\n;; stamp " stamp))
                    #:selection (list (caret p))))
  (struct-copy app a [ed ed*]))

;; 2.6 视图面：尺寸
;; [core] editor-set-size ed h w —— focus 糖（内部 = editor-view-set-size + 焦点 vid）。
;; [意图] 尺寸是「怎么看你」，属于视图面；同 buffer 的其它 view 不受影响。
(define (resize a rows cols)
  (struct-copy app a
    [rows rows] [cols cols]
    [ed (editor-set-size (app-ed a) (max 1 (sub1 rows)) (max 1 cols))]))

;;; ---------- 2.8 标注：关键字高亮（应用策略）----------
;;
;; [core] face-provider = buffer × line -> (listof (list start end face))；投影时按需调用。
;; [意图] 派生 face **不进文档**：没有存储、没有失效、没有重算。投影时现算。
;; [前端] 「什么算关键字、用哪个 key」全是应用策略；core 不解释 face 的值。
(define keyword-rx
  #px"\\b(define|lambda|if|cond|let|for|match|and|or|not|else)\\b")

;; 一个 face-provider：逐行扫关键字，返回本行的 (起列 止列 face) 段。
(define (syntax-face b line)
  (for/list ([m (in-list (regexp-match-positions* keyword-rx (buffer-line-ref b line)))])
    (list (car m) (cdr m) (hash 'face 'keyword))))

;; 应用按开关选 provider；投影时传给 editor->screen。
(define (app-face-provider a)
  (if (app-highlight? a) syntax-face (lambda (_b _line) '())))

;; 开关高亮：只翻标志，不碰文档。
(define (toggle-highlight a)
  (struct-copy app a [highlight? (not (app-highlight? a))]))

;;; ---------- 2.9 选中 / 多光标（应用策略） ----------
;;
;; [core] editor-selections / editor-set-selections / editor-add-selections / editor-primary /
;;        editor-point / editor-buffer->string / editor-buffer-offset->point / selection / caret …
;;        core 只给「选区集合 + 增删改」和「按所有选区批量替换」；「选哪个词、选下一个、全选同词」
;;        全是应用策略。
;; [前端] 词边界、搜索方式、Ctrl+D 的推进规则，都由应用决定。

;; 「词」：主选区非空 → 选区文本；否则取光标处/紧邻的 [A-Za-z0-9_] 串。
(define (word-at ed)
  (define bid (editor-buffer-id ed))
  (define prim (editor-primary ed))
  (if (and prim (not (caret? prim)))
      (let-values ([(a b) (selection-range prim)])
        (values (editor-buffer-range-text ed bid a b) a b))
      (let* ([p (editor-point ed)]
             [line (editor-buffer-line-ref ed bid (point-line p))]
             [n (string-length line)] [col (point-col p)]
             [w? (lambda (c) (or (char-alphabetic? c) (char-numeric? c) (char=? c #\_)))]
             [start (let loop ([i col]) (if (and (> i 0) (w? (string-ref line (sub1 i)))) (loop (sub1 i)) i))]
             [end (let loop ([i col]) (if (and (< i n) (w? (string-ref line i))) (loop (add1 i)) i))])
        (if (< start end)
            (values (substring line start end)
                    (point (point-line p) start) (point (point-line p) end))
            (values #f #f #f)))))

;; 全 buffer 里 pattern 的全部出现（按文档顺序）
(define (occurrences ed pattern)
  (define bid (editor-buffer-id ed))
  (define full (editor-buffer->string ed bid))
  (for/list ([m (in-list (regexp-match-positions* (regexp-quote pattern) full))])
    (list (editor-buffer-offset->point ed bid (car m))
          (editor-buffer-offset->point ed bid (cdr m)))))

;; Ctrl+D：光标→先选词；已有选区→再选「最后一个选区之后」的下一个相同串
(define (select-next-occurrence a)
  (define ed (app-ed a))
  (define-values (pat ps pe) (word-at ed))
  (cond
    [(not pat) a]
    [else
     (define prim (editor-primary ed))
     (cond
       [(caret? prim)                              ; 第一次：把 primary 扩成词
        (struct-copy app a [ed (editor-map-primary ed (lambda (_s) (selection ps pe)))])]
       [else                                       ; 已有：选 primary 之后、尚未选中的下一个出现
        (define prim-end (let-values ([(_ e) (selection-range prim)]) e))
        (define nxt (for/first ([o (in-list (occurrences ed pat))]
                                #:when (and (point<=? prim-end (car o))
                                            (not (editor-selection-member? ed (selection (car o) (cadr o))))))
                      o))
        (cond
          [(not nxt) a]
          [else (struct-copy app a [ed (editor-add-selection ed (selection (car nxt) (cadr nxt)) #:primary? #t)])])])]))

;; Ctrl+A：把当前词的所有出现一次选中
(define (select-all-occurrences a)
  (define ed (app-ed a))
  (define-values (pat _ps _pe) (word-at ed))
  (if (not pat)
      a
      (struct-copy app a
        [ed (editor-set-selections
             ed
             (map (lambda (o) (selection (car o) (cadr o))) (occurrences ed pat)))])))

;; 回单光标（保留 primary）
(define (collapse-selection a)
  (struct-copy app a [ed (editor-collapse-selections (app-ed a))]))

;; Shift+方向：只移动 primary 的 head，anchor 不动 → 扩选。
(define (extend-selection a sym)
  (define ed (app-ed a))
  (define b (editor-buffer ed (editor-buffer-id ed)))
  (define w (editor-window ed))
  (struct-copy app a
    [ed (editor-map-primary ed
          (lambda (s)
            (define h (selection-point s))
            (define h* (case sym
                         [(left)  (point-left b h)]     [(right) (point-right b h)]
                         [(up)    (point-up w h)]       [(down)  (point-down w h)]
                         [(home)  (point-home h)]       [(end)   (point-end b h)]))
            (selection (selection-anchor s) h*)))]))

;; 加一个光标（Alt+上下）
(define (add-caret a p)
  (struct-copy app a [ed (editor-add-selection (app-ed a) (caret p))]))
(define (add-caret-vertical a delta)
  (define ed (app-ed a))
  (define w (editor-window ed))
  (add-caret a (if (> delta 0) (point-down w (editor-point ed))
                                (point-up w (editor-point ed)))))

;;; ============================================================================
;;; §3 渲染（[前端]；core 只给 screen）
;;; ============================================================================
;;
;; [core] editor->screen → screen：**两条通道**分开给：
;;          row-runs（文档文本 + face）、cursors / selections（视图 overlay，带语义 face）。
;;        core **不知道**终端，也**不给颜色**；face 是语义 hash，映射成样式是应用的事。
;; [前端] 终端字节、颜色、叠加顺序，全是应用的事。

(define (face-style face)
  (case (hash-ref face 'face #f)
    [(keyword)   'info]
    [(comment)   'green]
    [(string)    'yellow]
    [(error)     'error]
    [(cursor)    'cursor]
    [(selection) 'selection]
    [else #f]))

(define (pad-to s n)
  (if (>= (string-length s) n)
      (substring s 0 n)
      (string-append s (make-string (- n (string-length s)) #\space))))

;; 从一行的 runs 里取显示列 [a,b) 的文本（宽字符按显示列切）
(define (runs-substring runs a b)
  (define out (open-output-string))
  (for ([r (in-list runs)])
    (define rcol (run-col r))
    (define rtext (run-text r))
    (define rw (string-display-width rtext))
    (define lo (max a rcol))
    (define hi (min b (+ rcol rw)))
    (when (< lo hi)
      (display (substring rtext (column->index rtext (- lo rcol)) (column->index rtext (- hi rcol)))
               out)))
  (get-output-string out))

;; 一个显示单元格上的字符（EOL / 空位 → 空格），用来把一个光标画成一格
(define (cell-text runs col)
  (or (for/first ([r (in-list runs)]
                  #:when (let ([rc (run-col r)])
                           (and (<= rc col) (< col (+ rc (string-display-width (run-text r)))))))
        (string (string-ref (run-text r) (column->index (run-text r) (- col (run-col r))))))
      " "))

(define (frame->bytes app)
  (define scr (editor->screen (app-ed app) (app-face-provider app)))
  (define row-runs (screen-row-runs scr))
  (define parts (list format-cursor-hide format-screen-clear))
  (define (emit! b) (set! parts (cons b parts)))
  ;; 1) 文档文本
  (for ([runs (in-vector row-runs)] [row (in-naturals)])
    (for ([r (in-list runs)])
      (emit! (format-cursor-move (add1 row) (add1 (run-col r))))
      (define st (face-style (run-face r)))
      (emit! (if st (format-styled st (run-text r)) (format-content (run-text r))))))
  ;; 2) 选中区：叠加层——把区间文本重画成 selection 样式
  (for ([g (in-list (screen-selections scr))])
    (define txt (runs-substring (vector-ref row-runs (region-row g))
                                (region-start-col g) (region-end-col g)))
    (unless (string=? txt "")
      (emit! (format-cursor-move (add1 (region-row g)) (add1 (region-start-col g))))
      (emit! (format-styled 'selection txt))))
  ;; 3) 所有光标：终端只有一个硬件光标，多光标只能画成格子（primary? 供前端区分样式）
  (for ([c (in-list (screen-cursors scr))])
    (emit! (format-cursor-move (add1 (cursor-row c)) (add1 (cursor-col c))))
    (emit! (format-styled 'cursor (cell-text (vector-ref row-runs (cursor-row c)) (cursor-col c)))))
  ;; 状态栏（最后一行）
  (define p (editor-point (app-ed app)))
  (define status
    (format " ~a  L~a:C~a  sel~a  ~a  ^Z^Y ^D next ^A all ^G ^L ^Q"
            (app-name app) (add1 (point-line p)) (add1 (point-col p))
            (length (editor-selections (app-ed app)))
            (if (app-highlight? app) "hl:on" "hl:off")))
  (emit! (format-cursor-move (app-rows app) 1))
  (emit! (format-styled 'status-bar (pad-to status (app-cols app))))
  ;; 光标已画成格子 → 始终隐藏硬件光标
  (emit! format-cursor-hide)
  (apply bytes-append (reverse parts)))

;;; ============================================================================
;;; §4 事件 → 命令（[前端] 映射；命令本身在 §2）
;;; ============================================================================
;;
;; [core] 事件类型（text/key/resize/quit 等）在 core 定义；这里由 racket-tui 的
;;        build-input 分好类，所以只写回调。
;; [前端] 按键 → 命令的映射、Ctrl 组合，都是应用策略。

(define (run path)
  (with-tui
   (lambda ()
     (enable-bracketed-paste!)
     (define-values (rows0 cols0) (get-window-size))
     (define app (open-app path (max 2 rows0) (max 1 cols0)))
     (define running? #t)
     (define (redraw) (put-bytes (frame->bytes app)))

     (define handler
       (build-input
        #:text      (lambda (str)  (set! app (edit app (edit-insert str))))
        #:enter     (lambda ()     (set! app (newline app)))
        #:backspace (lambda ()     (set! app (edit app (edit-backspace))))
        #:delete    (lambda ()     (set! app (edit app (edit-delete))))
        #:tab       (lambda ()     (set! app (edit app (edit-insert "  "))))
        #:left      (lambda ()     (set! app (navigate app 'left)))
        #:right     (lambda ()     (set! app (navigate app 'right)))
        #:up        (lambda ()     (set! app (navigate app 'up)))
        #:down      (lambda ()     (set! app (navigate app 'down)))
        #:home      (lambda ()     (set! app (navigate app 'home)))
        #:end       (lambda ()     (set! app (navigate app 'end)))
        #:pageup    (lambda ()     (set! app (navigate app 'pageup)))
        #:pagedown  (lambda ()     (set! app (navigate app 'pagedown)))
        #:escape    (lambda ()     ; 有选区/多光标 → 先回单光标；否则退出
                      (define sels (editor-selections (app-ed app)))
                      (if (or (> (length sels) 1) (for/or ([s sels]) (not (caret? s))))
                          (set! app (collapse-selection app))
                          (set! running? #f)))
        #:key       (lambda (key mods)
                      (cond
                        [(and (symbol? key) (mods-shift? mods))
                         (case key
                           [(left)  (set! app (extend-selection app 'left))]
                           [(right) (set! app (extend-selection app 'right))]
                           [(up)    (set! app (extend-selection app 'up))]
                           [(down)  (set! app (extend-selection app 'down))]
                           [(home)  (set! app (extend-selection app 'home))]
                           [(end)   (set! app (extend-selection app 'end))]
                           [else (void)])]
                        [(and (symbol? key) (mods-alt? mods) (memq key '(up down)))
                         (set! app (add-caret-vertical app (if (eq? key 'down) 1 -1)))]
                        [(and (char? key) (mods-ctrl? mods))
                         (case key
                           [(#\Z) (set! app (run-ed app editor-undo))]
                           [(#\Y) (set! app (run-ed app editor-redo))]
                           [(#\D) (set! app (select-next-occurrence app))]
                           [(#\A) (set! app (select-all-occurrences app))]
                           [(#\G) (set! app (append-stamp app))]
                           [(#\L) (set! app (toggle-highlight app))]
                           [(#\Q) (set! running? #f)]
                           [else (void)])]
                        [else (void)]))
        #:resize    (lambda (rows cols) (set! app (resize app (max 2 rows) (max 1 cols))))))

     (define (step ev) (handler ev) (redraw))
     (redraw)
     (loop-input/stop (not running?) step))))

;;; ============================================================================
;;; §5 测试（纯命令，不开终端）
;;; ============================================================================

(module+ test
  (require rackunit)

  ;; 用户面编辑 + 撤销
  (define a0 (make-app "" 5 20 "*t*"))
  (define a1 (edit a0 (edit-insert "abc")))
  (check-equal? (editor-buffer->string (app-ed a1) 0) "abc")
  (check-equal? (editor-point (app-ed a1)) (point 0 3))
  (define a2 (run-ed a1 editor-undo))
  (check-equal? (editor-buffer->string (app-ed a2) 0) "")

  ;; 自定义 op：自动缩进
  (define a3 (make-app "  x" 5 20 "*t*"))
  (define a4 (navigate a3 'end))
  (define a5 (newline a4))
  (check-equal? (editor-buffer->string (app-ed a5) 0) "  x\n  ")

  ;; 程序编辑：追加时间戳不改光标（editor-command，reaction 'none）
  (define a6 (edit (make-app "hi" 5 20 "*t*") (edit-insert "!")))   ; → "!hi"，光标 (0,1)
  (define a7 (append-stamp a6))
  (check-equal? (editor-point (app-ed a7)) (point 0 1))       ; 光标没动
  (check-true (regexp-match? #rx";; stamp" (editor-buffer->string (app-ed a7) 0)))

  ;; 标注：派生 face 在投影时出现（文档里根本没有 face 这个概念）
  (define a8 (edit (make-app "" 5 20 "*t*") (edit-insert "define x")))
  (check-equal? (run-face (car (vector-ref (screen-row-runs (editor->screen (app-ed a8) (app-face-provider a8))) 0)))
                (hash 'face 'keyword))                                        ; 投影里有
  (define a9 (toggle-highlight a8))                                          ; 关 → provider 返回空
  (check-equal? (run-face (car (vector-ref (screen-row-runs (editor->screen (app-ed a9) (app-face-provider a9))) 0)))
                (hash))

  ;; 视图面：resize 只改 view，不动文本
  (define a10 (resize a8 8 30))
  (check-equal? (editor-height (app-ed a10)) 7)
  (check-equal? (editor-buffer->string (app-ed a10) 0) "define x")

  ;; 选中/多光标（前端策略）：Ctrl+D 选词 → 再选下一个 → 一起替换
  (define m0 (make-app "foo bar foo" 5 20 "*t*"))
  (define m1 (select-next-occurrence m0))
  (check-equal? (length (editor-selections (app-ed m1))) 1)      ; 光标→先选词
  (define m2 (select-next-occurrence m1))
  (check-equal? (length (editor-selections (app-ed m2))) 2)      ; 再选下一个相同串
  (define m3 (edit m2 (edit-insert "X")))                        ; 两个一起替换
  (check-equal? (editor-buffer->string (app-ed m3) 0) "X bar X")
  (check-equal? (length (editor-selections (app-ed (collapse-selection m3)))) 1)
  ;; 全选同词
  (define m4 (select-all-occurrences m0))
  (check-equal? (length (editor-selections (app-ed m4))) 2)
  (check-equal? (editor-buffer->string (app-ed (edit m4 (edit-insert "Y"))) 0) "Y bar Y")
  ;; Shift+右：扩选（主选区 head 动、anchor 不动）
  (define m5 (extend-selection m0 'right))
  (check-true (not (caret? (car (editor-selections (app-ed m5))))))
  ;; 渲染：多选区时 screen 两条通道都在，能出帧
  (check-true (bytes? (frame->bytes m2)))
  (check-equal? (length (screen-selections (editor->screen (app-ed m2)))) 2)
  (check-equal? (length (screen-cursors (editor->screen (app-ed m2)))) 2)

  ;; 跨行选区（Shift+↓）后删除
  (define x0 (make-app "abc\ndef\nghi" 6 20 "*t*"))
  (define x1 (navigate x0 'down))
  (define x2 (extend-selection x1 'down))
  (check-true (not (caret? (car (editor-selections (app-ed x2))))))
  (define x3 (edit x2 (edit-backspace)))
  (check-equal? (editor-buffer->string (app-ed x3) 0) "abc\nghi")
  (check-true (bytes? (frame->bytes x3)))

  (displayln "example.rkt: all tests passed"))

(module+ main
  (define args (current-command-line-arguments))
  (run (and (> (vector-length args) 0) (vector-ref args 0))))

;;; ============================================================================
;;; §6 本示例暴露的 core 改进线索（汇总）
;;; ============================================================================
;;
;; 1. report 粒度：change-report 只给「首行/末行 + descs」（行区间由 edits 现算）。
;;    前端若要按**每个**变更区间做增量处理，需自己走 change-report-edits。
;; 2. 无「多窗格布局」原语：分屏 / 拼接要前端自己做（`screen-compose` 已给拼屏，
;;    但 view 的摆放、焦点切换策略不在 core）。
