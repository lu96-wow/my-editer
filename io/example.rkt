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
;;; 运行：  racket io/example.rkt [文件]   （无文件 → 内置示例文本）
;;; 按键：  可打印/中文 插入   Enter 自动缩进换行   Backspace/Delete 删除   Tab 两空格
;;;         ←→↑↓ Home End PgUp PgDn 导航   Shift+方向 扩选   Alt+↑↓ 上下加光标
;;;         ^D 选中下一个相同串（多光标）  ^A 选中全部相同串  Esc 回单光标/退出
;;;         ^W 切换左右窗格    ^Z 撤销  ^Y 重做  ^G 程序面追加时间戳  ^O 标记只读
;;;         ^K 清除只读  ^L 开关高亮  ^N 开关行号栏  ^Q 退出
;;;
;;; 左右两个窗格是**两个不同的 document**（右为镜像），用 core 的**跨 document 视口同步**
;;; （`editor-link-views`）链接：滚动/导航一个，另一个按「行固定、列按比例」跟随。

(require "../core/editor.rkt"   ; editor 平台面（中性/程序/用户）
         "../core/api.rkt"      ; 低层公开面（point/selection/edit-desc/attr/window/screen/…）
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

(struct app (ed rows cols name highlight? mirror-vid) #:transparent)
;; ed        : editor
;; rows/cols : nat      终端整屏尺寸（最后一行留作状态栏）
;; name      : string
;; highlight? : boolean 是否跑关键字高亮
;; mirror-vid : view-id 右窗格视图（看第二个 document）

;; 分屏几何：左 pane 宽 = cols/2，右 = 其余；内容高 = rows-1（最后一行状态栏）。
(define (pane-left-w cols)  (max 1 (quotient cols 2)))
(define (pane-right-w cols) (max 1 (- cols (pane-left-w cols))))
(define (set-pane-sizes ed mvid rows cols)
  (define h (max 1 (sub1 rows)))
  (editor-view-set-size (editor-view-set-size ed 0 h (pane-left-w cols)) mvid h (pane-right-w cols)))

;; 无文件时的默认内容（够长，能看出滚动同步）
(define default-doc
  (string-join
   '(";; 示例：左右两个 document，用跨 document 视口同步链接起来"
     ";; 左 pane = 主文档；右 pane = 行号镜像（另一个 document）"
     ";; 按 ↓ / PgDn 滚动，右侧按『行固定』跟随；^W 切换焦点"
     ""
     "(define (fact n)"
     "  (if (zero? n)"
     "      1"
     "      (* n (fact (sub1 n)))))"
     ""
     "(define (map1 f xs)"
     "  (cond [(null? xs) '()]"
     "        [else (cons (f (car xs))"
     "                    (map1 f (cdr xs)))]))"
     ""
     ";; 中文行也同步：宽字符按显示宽算"
     ";; 左右 pane 列宽不同时，水平滚动按比例映射"
     ""
     "(struct point (line col) #:transparent)"
     "(define origin (point 0 0))"
     ""
     "(define (repeat n x)"
     "  (if (zero? n) '() (cons x (repeat (sub1 n) x))))"
     ""
     "(provide fact map1 point origin repeat)"
     ""
     ";; 下面这段只为把行数拉长，方便看滚动"
     "(define (foldl f acc xs)"
     "  (if (null? xs) acc (foldl f (f acc (car xs)) (cdr xs))))"
     ""
     "(define (range0 n) (map1 (lambda (i) i) (repeat n 0)))")
   "\n"))

;; 右 pane 文档：把主文本渲染成「行号 | 原文」（行数一致，但内容/列宽明显不同）
(define (mirror-of text)
  (string-join
   (for/list ([ln (in-list (string-split text #rx"\r?\n" #:trim? #f))] [i (in-naturals)])
     (format "~a | ~a" (add1 i) ln))
   "\n"))

(define (make-app text rows cols name)
  (define h (max 1 (sub1 rows)))
  (define ed0 (editor-open text h (pane-left-w cols) #:name name))
  ;; 第二个 document（镜像，独立文本；`#:history? #f`：派生 UI 不进历史）
  (define-values (ed1 mdid) (editor-open-document ed0 (mirror-of text) h (pane-right-w cols)
                                                  #:name "mirror" #:focus? #f #:history? #f))
  ;; 链接两个 view：跨 document 视口同步（行固定、列按比例）；用 editor 层读口直接拿到镜像 document 的 view
  (define mvid (editor-document-view ed1 mdid))
  (app (editor-link-views ed1 'mirror (list 0 mvid)) rows cols name #t mvid))

(define (open-app path rows cols)
  (make-app (if (and path (file-exists? path)) (file->string path) default-doc)
            rows cols
            (if path (path->string (file-name-from-path path)) "*scratch*")))

;;; ============================================================================
;;; §2 组合操作（每条都标了 [core]/[意图]/[前端]）
;;; ============================================================================

;; 2.0 编辑：core 没有「重算」步骤
;; [core] editor-edit ed op → (values editor report)，用户编辑（leader + 记账）。
;;        文本变；派生标注走投影 provider（不存，无过期）；作者态属性随编辑自动移动。
;; [意图] 编辑路径与标注解耦：report 只给生效 desc，是否重算/重划由应用决定（见 2.8）。
;;
;; core 命令有两种返回形状：editor（视图命令）或 (values editor report)（编辑 / 账本）。
;; 这里只把 editor 塞回 app；report 前端不用。
(define (run-ed a f)
  (define-values (ed _report) (f (app-ed a)))
  (struct-copy app a [ed ed]))

;; 一次用户编辑：op : buffer selection → edit-desc。
(define (edit a op) (run-ed a (lambda (ed) (editor-edit ed op))))

;; 2.2 回车：自动缩进
;; [core] op 是**值**：`editor did selection -> edit-desc`；读文本用 editor 级读口。
;; [意图] 自动缩进 = 插 "\n" + 当前行前导空白，必须读当前行，所以用自定义 op；
;;        edit-newline 只会插一个 "\n"，做不到。
;; [前端] 缩进宽度、是否缩进，是应用策略。
(define (newline app)
  (edit app
        (lambda (ed did sel)
          (define p (selection-head sel))
          (define line (editor-buffer-line-ref ed did (point-line p)))
          (define indent (car (regexp-match #rx"^[ \t]*" line)))
          (define-values (a z) (selection-range sel))
          (edit-desc a z (string-append "\n" indent)))))

;; 2.3 导航
;; [core] editor-left/right/up/down/home/end/scroll（命名用户命令，内部走 editor-command 组合）。
;; [意图] 用户导航 = 动焦点光标 + 保证可见 + 同 document 的 follow 视图镜像。
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
  (define did (editor-document-id ed))
  (define n (editor-buffer-line-count ed did))
  (define p (point (sub1 n) (editor-buffer-line-length ed did (sub1 n))))
  (define stamp (number->string (current-seconds)))
  (define-values (ed* _report)
    (editor-command ed (edit-insert (string-append "\n;; stamp " stamp))
                    #:selection (list (caret p))
                    #:record? #f))
  (struct-copy app a [ed ed*]))

;; 2.6 视图面：尺寸
;; [core] editor-set-size ed h w —— focus 糖（内部 = editor-view-set-size + 焦点 vid）。
;; [意图] 尺寸是「怎么看你」，属于视图面；同 document 的其它 view 不受影响。
(define (resize a rows cols)
  (struct-copy app a
    [rows rows] [cols cols]
    [ed (set-pane-sizes (app-ed a) (app-mirror-vid a) rows cols)]))

;;; ---------- 2.8 标注：两种来源，投影时汇合（应用策略）----------
;;
;; [core] 标注有两条路，最后都变成**投影参数 face-provider**（editor did line → runs）：
;;   ① 派生（content 的纯函数，如语法高亮）→ 纯 provider：不存、不失效、不重算；
;;   ② 作者态/外部（如只读标记）→ 属性 buffer：写一次随编辑移动，投影时读。
;; [前端] 「什么算关键字 / 什么算只读 / 用哪个 key」全是应用策略；core 不解释值。
(define keyword-rx
  #px"\\b(define|lambda|if|cond|let|for|match|and|or|not|else)\\b")

;; ① 派生：逐行扫关键字，返回本行的 (起列 止列 face) 段。
(define (syntax-face ed did line)
  (for/list ([m (in-list (regexp-match-positions* keyword-rx
                                                   (editor-buffer-line-ref ed did line)))])
    (list (car m) (cdr m) (hash 'face 'keyword))))

;; ② 作者态：把主选区涉及的每行区间标为只读（core 保留 key）。
;;    选区 → (list (line c0 c1))；跨行时首/末行取列区间，中间行整行。
(define (selection-line-spans ed did s e)
  (define sl (point-line s)) (define sc (point-col s))
  (define el (point-line e)) (define ec (point-col e))
  (cond
    [(= sl el) (list (list sl sc ec))]
    [else
     (append (list (list sl sc (editor-buffer-line-length ed did sl)))
             (for/list ([l (in-range (add1 sl) el)])
               (list l 0 (editor-buffer-line-length ed did l)))
             (list (list el 0 ec)))]))

(define (mark-read-only a)
  (define ed (app-ed a))
  (define did (editor-document-id ed))
  (define sel (editor-primary ed))
  (if (caret? sel)
      a
      (let-values ([(s e) (selection-range sel)])
        ;; [core] 一次 editor-apply-attrs = 一条 change 命令：批量、一次 swap、一步撤销。
        (define attrs
          (for/list ([sp (in-list (selection-line-spans ed did s e))]
                     #:when (< (cadr sp) (caddr sp)))
            (match-define (list line c0 c1) sp)
            (attr-set (point line c0) (point line c1) read-only-key #t)))
        (define-values (ed* _r) (editor-apply-attrs ed did attrs #:record? #t))
        (struct-copy app a [ed ed*]))))

(define (clear-read-only a)
  (define ed (app-ed a))
  (define did (editor-document-id ed))
  (define sel (editor-primary ed))
  (if (caret? sel)
      a
      (let-values ([(s e) (selection-range sel)])
        (define attrs
          (for/list ([sp (in-list (selection-line-spans ed did s e))]
                     #:when (< (cadr sp) (caddr sp)))
            (match-define (list line c0 c1) sp)
            (attr-remove (point line c0) (point line c1) read-only-key)))
        (define-values (ed* _r) (editor-apply-attrs ed did attrs #:record? #t))
        (struct-copy app a [ed ed*]))))

;; 属性 buffer → face：只读段读出来当样式（其它 key 同理）。
(define (read-only-face ed did line)
  (for/list ([r (in-list (editor-attr-key-runs ed did line read-only-key))])
    (list (car r) (cadr r) (hash 'face 'read-only))))

;; 投影：两个来源拼成一个 provider（后者覆盖前者）；传给 editor->screen。
(define (app-face-provider a)
  (lambda (ed did line)
    (append (if (app-highlight? a) (syntax-face ed did line) '())
            (read-only-face ed did line))))

;; 开关高亮：只翻标志，不碰文档。
(define (toggle-highlight a)
  (struct-copy app a [highlight? (not (app-highlight? a))]))

;; 开关行号栏（core 视图装饰；只动焦点 view，不碰文档）
(define (toggle-line-numbers a)
  (struct-copy app a
    [ed (editor-set-line-numbers (app-ed a) (not (editor-line-numbers? (app-ed a))))]))

;;; ---------- 2.9 选中 / 多光标（应用策略） ----------
;;
;; [core] editor-selections / editor-set-selections / editor-add-selections / editor-primary /
;;        editor-point / editor-buffer->string / editor-buffer-offset->point / selection / caret …
;;        core 只给「选区集合 + 增删改」和「按所有选区批量替换」；「选哪个词、选下一个、全选同词」
;;        全是应用策略。
;; [前端] 词边界、搜索方式、Ctrl+D 的推进规则，都由应用决定。

;; 「词」：主选区非空 → 选区文本；否则取光标处/紧邻的 [A-Za-z0-9_] 串。
(define (word-at ed)
  (define did (editor-document-id ed))
  (define prim (editor-primary ed))
  (if (and prim (not (caret? prim)))
      (let-values ([(a b) (selection-range prim)])
        (values (editor-buffer-range-text ed did a b) a b))
      (let* ([p (editor-point ed)]
             [line (editor-buffer-line-ref ed did (point-line p))]
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
  (define did (editor-document-id ed))
  (define full (editor-buffer->string ed did))
  (for/list ([m (in-list (regexp-match-positions* (regexp-quote pattern) full))])
    (list (editor-buffer-offset->point ed did (car m))
          (editor-buffer-offset->point ed did (cdr m)))))

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
  (struct-copy app a
    [ed (editor-map-primary ed
          (lambda (s)
            (define h (selection-point s))
            (define h* (case sym
                         [(left)  (editor-point-left ed h)]  [(right) (editor-point-right ed h)]
                         [(up)    (editor-point-up ed h)]    [(down)  (editor-point-down ed h)]
                         [(home)  (editor-point-home ed h)]  [(end)   (editor-point-end ed h)]))
            (selection (selection-anchor s) h*)))]))

;; 加一个光标（Alt+上下）
(define (add-caret a p)
  (struct-copy app a [ed (editor-add-selection (app-ed a) (caret p))]))
(define (add-caret-vertical a delta)
  (define ed (app-ed a))
  (add-caret a (if (> delta 0) (editor-point-down ed (editor-point ed))
                                (editor-point-up ed (editor-point ed)))))

;; 切换窗格：把焦点在左（view 0）与右（mirror view）之间切
(define (switch-pane a)
  (define ed (app-ed a))
  (define mvid (app-mirror-vid a))
  (struct-copy app a [ed (editor-focus-view ed (if (= (editor-focus ed) 0) mvid 0))]))

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
    [(read-only) 'error]
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
  (define ed (app-ed app))
  (define mvid (app-mirror-vid app))
  (define fvid (editor-focus ed))
  ;; 两个 pane 各自投影成 screen，再拼成整屏；只有活动 pane 的光标透出
  (define scr
    (screen-compose (max 1 (sub1 (app-rows app))) (app-cols app)
                    (list (list 'left  0 0 (editor-view->screen ed 0 (app-face-provider app)))
                          (list 'right (pane-left-w (app-cols app)) 0
                                (editor-view->screen ed mvid (app-face-provider app))))
                    (if (= fvid 0) 'left 'right)))
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
  ;; 状态栏（最后一行）：左右 top-line + 活动窗格
  (define p (editor-point (app-ed app)))
  (define status
    (format " ~a  L~a:C~a  sel~a  | L~a L~a  pane:~a  ~a  ^W switch ^Z^Y ^D ^A ^G ^O ^K ^L ^Q"
            (app-name app) (add1 (point-line p)) (add1 (point-col p))
            (length (editor-selections (app-ed app)))
            (editor-view-top-line (app-ed app) 0) (editor-view-top-line (app-ed app) mvid)
            (if (= fvid 0) "L" "R")
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
                           [(#\O) (set! app (mark-read-only app))]
                           [(#\K) (set! app (clear-read-only app))]
                           [(#\L) (set! app (toggle-highlight app))]
                           [(#\N) (set! app (toggle-line-numbers app))]
                           [(#\W) (set! app (switch-pane app))]
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

  ;; 作者态属性（属性 buffer）：标记只读 → 投影出样式；守卫拦编辑；清除后恢复
  (define r0 (make-app "hello world" 5 20 "*t*"))
  (define r1 (struct-copy app r0
               [ed (editor-set-selections (app-ed r0)
                                          (list (selection (point 0 0) (point 0 5))))]))
  (define r2 (mark-read-only r1))
  (check-equal? (editor-attr-key-runs (app-ed r2) 0 0 read-only-key) (list (list 0 5 #t)))
  (check-equal? (run-face (car (vector-ref (screen-row-runs (editor->screen (app-ed r2) (app-face-provider r2))) 0)))
                (hash 'face 'read-only))
  ;; 只读区内插入被守卫拒绝
  (define r3 (struct-copy app r2 [ed (editor-set-selections (app-ed r2) (list (caret (point 0 2))))]))
  (define r4 (edit r3 (edit-insert "X")))
  (check-equal? (editor-buffer->string (app-ed r4) 0) "hello world")
  ;; 清除只读 → 可编辑
  (define r5 (struct-copy app r4 [ed (editor-set-selections (app-ed r4)
                                                            (list (selection (point 0 0) (point 0 5))))]))
  (define r6 (clear-read-only r5))
  (check-false (attr-read-only? (editor-attr-at (app-ed r6) 0 (point 0 2))))
  (define r7 (struct-copy app r6 [ed (editor-set-selections (app-ed r6) (list (caret (point 0 0))))]))
  (check-equal? (editor-buffer->string (app-ed (edit r7 (edit-insert "X"))) 0) "Xhello world")

  ;; 视图面：resize 只改 view，不动文本
  (define a10 (resize a8 8 30))
  (check-equal? (editor-height (app-ed a10)) 7)
  (check-equal? (editor-buffer->string (app-ed a10) 0) "define x")

  ;; 选中/多光标（前端策略）：Ctrl+D 选词 → 再选下一个 → 一起替换
  (define m0 (make-app "foo bar foo" 5 40 "*t*"))
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

  ;; 反向选区（Shift+左/上 可能产生）：插入 / 回车按正向区间替换，不得报错
  (define rv0 (make-app "abcdef" 5 20 "*t*"))
  (define rv1 (struct-copy app rv0
               [ed (editor-set-selections (app-ed rv0)
                                          (list (selection (point 0 4) (point 0 1))))]))
  (check-equal? (editor-buffer->string (app-ed (edit rv1 (edit-insert "X"))) 0) "aXef")
  (check-equal? (editor-buffer->string (app-ed (edit rv1 (edit-newline))) 0) "a\nef")
  (check-equal? (editor-buffer->string (app-ed (edit rv1 (edit-backspace))) 0) "aef")

  ;; 分屏 + 跨 document 视口同步：左右是两个 document，链接后滚动一个另一个跟随
  (define p0 (make-app (string-join (for/list ([i (in-range 30)]) (format "line ~a" i)) "\n") 8 40 "*p*"))
  (check-equal? (editor-document-count (app-ed p0)) 2)                     ; 两个 document
  (check-equal? (editor-view-link (app-ed p0) 0) 'mirror)                  ; 左 pane 在链接里
  (check-equal? (editor-view-link (app-ed p0) (app-mirror-vid p0)) 'mirror)
  (define p1 (for/fold ([a p0]) ([_ (in-range 12)]) (navigate a 'down)))  ; 左 pane 下移出屏
  (check-true (> (editor-view-top-line (app-ed p1) 0) 0))                  ; 确实滚了
  (check-equal? (editor-view-top-line (app-ed p1) (app-mirror-vid p1))     ; 右 pane 跟随
                (editor-view-top-line (app-ed p1) 0))
  (check-true (bytes? (frame->bytes p1)))                                  ; 两 pane 能拼成一帧
  ;; ^W 切换窗格
  (define p2 (switch-pane p1))
  (check-equal? (editor-focus (app-ed p2)) (app-mirror-vid p1))
  (check-equal? (editor-focus (app-ed (switch-pane p2))) 0)

  ;; 行号栏开关：开 → screen 首 run 是 'line-number；关 → 回到文本首 run
  (define ln0 (make-app "a\nb\nc" 5 40 "*ln*"))
  (check-false (editor-line-numbers? (app-ed ln0)))
  (define ln1 (toggle-line-numbers ln0))
  (check-true (editor-line-numbers? (app-ed ln1)))
  (check-equal? (run-face (car (vector-ref (screen-row-runs (editor->screen (app-ed ln1))) 0)))
                (hash 'face 'line-number))
  (check-equal? (run-face (car (vector-ref (screen-row-runs (editor->screen (app-ed (toggle-line-numbers ln1)))) 0)))
                (hash))
  (check-true (bytes? (frame->bytes ln1)))                 ; 行号栏让出的宽度能渲染

  (displayln "example.rkt: all tests passed"))

(module+ main
  (define args (current-command-line-arguments))
  (run (and (> (vector-length args) 0) (vector-ref args 0))))

;;; ============================================================================
;;; §6 本示例暴露的 core 改进线索（汇总）
;;; ============================================================================
;;
;; 1. report 粒度：change-report 给「首行/末行 + 生效 texts + 生效 attrs」（行区间由 texts 现算）。
;;    前端若要按**每个**变更区间做增量处理，需自己走 change-report-texts / change-report-attrs。
;; 2. 多窗格布局：分屏 / 拼接要前端自己做（`screen-compose` 给拼屏）；
;;    但**跨 document 的视口同步**是 core 能力（`editor-link-views` + `viewport/mirror.rkt`），
;;    本示例就用它把左右两个 document 的窗格链接起来（`^W` 切换焦点）。
;; 3. 属性已是一等公民：editor-apply-attrs 批量写、进账本、replay/undo 精确；
;;    「插入文本 + 标只读」可用 editor-command 的 #:attrs 计划一次完成。
