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
;;;   [core]   用到的 core 能力（原子 / 文档 / 视口 / 平台各面）
;;;   [意图]   为什么选这个 api、为什么这个顺序、保证什么不变量
;;;   [前端]   应用自己的策略，core 不该管（高亮、终端、按键映射、状态栏）
;;;   [缺口]   core 目前缺失，导致这里要绕 —— 这是给你改进 core 的线索（§6 汇总）
;;;
;;; 数据驱动：应用状态是一个不可变 struct `app`；命令都是 `app -> app` 的纯函数；
;;; 只有最外层事件循环用 set! 更新一次。core 的 editor 只是 app 的一个字段。
;;;
;;; 运行：  racket io/example.rkt [文件]
;;; 按键：  可打印/中文 插入   Enter 自动缩进换行   Backspace/Delete 删除   Tab 两空格
;;;         ←→↑↓ Home End PgUp PgDn 导航   鼠标点击定位
;;;         ^Z 撤销  ^Y 重做  ^G 程序面追加时间戳  ^L 开关高亮  ^Q/Esc 退出

(require "../core/editor.rkt"
         ;; racket-tui 也导出 key-event/resize-event 等，与 core 同名；这里用 core 的。
         (except-in tui key-event key-event? key-event-key struct:key-event
                    resize-event resize-event? resize-event-rows resize-event-cols
                    struct:resize-event)
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
  (rehighlight-all
   (app (editor-open text (max 1 (sub1 rows)) cols #:name name)
        rows cols name #t)))

(define (open-app path rows cols)
  (make-app (if (and path (file-exists? path)) (file->string path) "")
            rows cols
            (if path (path->string (file-name-from-path path)) "*scratch*")))

;;; ============================================================================
;;; §2 组合操作（每条都标了 [core]/[意图]/[前端]/[缺口]）
;;; ============================================================================

;; 2.0 编辑后统一收口
;; [core] change-report = (首行, 末行, 施加顺序的生效 desc)；command 的第二个返回值。
;; [意图] 文本改了之后，高亮该重算哪几行，core 已经通过 report 告诉了我们（新坐标系），
;;        不需要前端自己 diff。
;; [前端] 「要不要重算高亮」是应用策略，所以包在 changed 里。
(define (changed a ed report)
  (define app* (struct-copy app a [ed ed]))
  (if (and (app-highlight? app*) report)
      (highlight-range app*
                       (editor-focused-buffer-id ed)
                       (change-report-first-line report)
                       (change-report-last-line report))
      app*))

;; 2.1 用户面编辑
;; [core] editor-edit ed op —— focus 糖，等价 (editor-view-edit ed (focused-vid ed) op)。
;; [意图] 按键编辑要同时发生三件事：改文本、光标推进到插入后并 ensure 可见、记一步账本。
;;        只有**用户面**同时具备；程序面 editor-edit-at 默认不动视图（那是给 LSP/脚本的）。
;; [缺口] editor-edit 与 editor-edit-at 各自实现了「施加→反应→记账→report」这一套，
;;        逻辑重叠。若给 editor-edit-at 一个 #:reaction 'leader 且带 vid，两个面就能合一。
(define (edit app op)
  (define-values (ed report) (editor-edit (app-ed app) op))
  (changed app ed report))

(define (insert-text app str) (edit app (edit-insert str)))
(define (delete-back app)     (edit app (edit-backspace)))
(define (delete-fwd app)      (edit app (edit-delete)))

;; 2.2 回车：自动缩进
;; [core] op 是**值**：`buffer point -> edit-desc`。可以自己写，先看 buffer 再决定插什么。
;; [意图] 自动缩进 = 插 "\n" + 当前行前导空白，必须读 buffer，所以用自定义 op；
;;        edit-newline 只会插一个 "\n"，做不到。
;; [前端] 缩进宽度、是否缩进，是应用策略。
(define (newline app)
  (edit app
        (lambda (b p)
          (define line (buffer-line-ref b (point-line p)))
          (define indent (car (regexp-match #rx"^[ \t]*" line)))
          (edit-desc p p (string-append "\n" indent)))))

;; 2.3 导航
;; [core] editor-left/right/up/down/home/end/scroll（focus 糖 → editor-view-* + ensure）。
;; [意图] 用户导航 = 动焦点光标 + 保证可见 + 同 buffer 的 follow 视图镜像；全在用户面。
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

;; 2.4 账本
;; [core] editor-undo / editor-redo —— 按焦点 view 所属 buffer 的账本；同样走 leader 语义。
;; [意图] 撤销也改文本，所以同样用返回的 change-report 重贴高亮。
(define (undo app) (define-values (ed r) (editor-undo (app-ed app))) (changed app ed r))
(define (redo app) (define-values (ed r) (editor-redo (app-ed app))) (changed app ed r))

;; 2.5 程序面：不打扰用户的编辑
;; [core] editor-edit-at ed bid point op，默认 #:reaction 'none。
;; [意图] 「在文件末尾追加时间戳」不该把用户光标拽走 —— 这正是**程序面**与用户面的区别，
;;        也是 core 「内容变更默认不动视图」的体现。
;; [缺口] 程序面没有 leader/ensure，所以「让某个 view 跟着这次程序编辑」只能自己映射，
;;        或退化成用户面（会抢焦点/改焦点 view）。这也是 2.1 说的合一动机。
(define (append-stamp app)
  (define ed (app-ed app))
  (define bid (editor-focused-buffer-id ed))
  (define n (editor-buffer-line-count ed bid))
  (define p (point (sub1 n) (editor-buffer-line-length ed bid (sub1 n))))
  (define stamp (number->string (current-seconds)))
  (define-values (ed* report)
    (editor-edit-at ed bid p (edit-insert (string-append "\n;; stamp " stamp))))
  (changed app ed* report))

;; 2.6 视图面：尺寸
;; [core] editor-view-set-size ed vid h w —— 按 vid 定位，只动那个 view，不碰焦点。
;; [意图] 尺寸是「怎么看你」，属于视图面；同 buffer 的其它 view 不受影响。
;; [缺口] 没有 editor-set-size 这样的 focus 糖，必须自己 (editor-focus) 取 vid。
(define (resize a rows cols)
  (struct-copy app a
    [rows rows] [cols cols]
    [ed (editor-view-set-size (app-ed a) (editor-focus (app-ed a))
                              (max 1 (sub1 rows)) (max 1 cols))]))

;; 2.7 鼠标：屏幕坐标 → 位置
;; [core] editor-screen->point（焦点 view）→ editor-goto（用户面，会滚屏保证可见）。
;; [意图] 坐标换算（宽字符、wrap）在 core 算好；把「点击」当用户导航，故会 ensure。
;; [前端] 「只有文本区（非状态行）才处理」是应用政策。
(define (click a x y)
  (if (>= y (sub1 (app-rows a)))
      a
      (let-values ([(l c) (editor-screen->point (app-ed a) y x)])
        (if l
            (struct-copy app a [ed (editor-goto (app-ed a) (point l c))])
            a))))

;;; ---------- 2.8 标注：关键字高亮（应用策略）----------
;;
;; [core] editor-apply-patches ed bid [patch]；patch = 对某 key 在 [first-line,last-line]
;;        「清旧写新」。行区间直接来自 change-report。
;; [意图] 用 patch 而不是 editor-put-property：
;;          patch 的语义就是「这几行我重新推导了」，自带清旧、天然增量；
;;          逐段 put 要自己算区间、还得先自己清旧，又慢又易错。
;; [前端] 「什么算关键字、用哪个 key、何时重扫」全是应用策略；core 不解释 face 的值。
;; [缺口] 编辑 + 高亮是**两趟写**（tick 涨 2）；core 没有「编辑时顺便产出标注」的事务/钩子。
;;        如果 core 能收一个「变更行区间 → patch」的纯函数，前端这层胶水就能消失。
(define keyword-rx
  #px"\\b(define|lambda|if|cond|let|for|match|and|or|not|else)\\b")

(define (syntax-segs app bid fl ll)
  (for*/list ([line (in-range fl (add1 ll))]
              [m (in-list (regexp-match-positions*
                           keyword-rx
                           (editor-buffer-line-ref (app-ed app) bid line)))])
    (list line (car m) (cdr m) 'keyword)))

(define (highlight-range a bid fl ll)
  (struct-copy app a
    [ed (editor-apply-patches (app-ed a) bid
                              (list (patch 'face fl ll (syntax-segs a bid fl ll))))]))

(define (rehighlight-all app)
  (define ed (app-ed app))
  (define bid (editor-focused-buffer-id ed))
  (highlight-range app bid 0 (sub1 (editor-buffer-line-count ed bid))))

(define (clear-highlight a)
  (define ed (app-ed a))
  (define bid (editor-focused-buffer-id ed))
  (struct-copy app a
    [ed (editor-apply-patches ed bid
                              (list (patch 'face 0 (sub1 (editor-buffer-line-count ed bid)) '())))]))

(define (toggle-highlight a)
  (define app* (struct-copy app a [highlight? (not (app-highlight? a))]))
  (if (app-highlight? app*) (rehighlight-all app*) (clear-highlight app*)))

;;; ============================================================================
;;; §3 渲染（[前端]；core 只给 screen）
;;; ============================================================================
;;
;; [core] editor->screen → screen（每行 runs + 一个光标位置）。core **不知道**终端。
;; [前端] 终端字节、颜色、状态栏、布局，全是应用的事。
;;        core 的 face 是语义 hash（'face → 'keyword…），映射成终端样式由应用决定。

(define (face-style face)
  (case (hash-ref face 'face #f)
    [(keyword) 'info]
    [(comment) 'green]
    [(string)  'yellow]
    [(error)   'error]
    [else #f]))

(define (pad-to s n)
  (if (>= (string-length s) n)
      (substring s 0 n)
      (string-append s (make-string (- n (string-length s)) #\space))))

(define (frame->bytes app)
  (define scr (editor->screen (app-ed app)))
  (define parts (list format-cursor-hide format-screen-clear))
  (define (emit! b) (set! parts (cons b parts)))
  ;; 画每行 runs
  (for ([runs (in-vector (screen-row-runs scr))] [row (in-naturals)])
    (for ([r (in-list runs)])
      (emit! (format-cursor-move (add1 row) (add1 (run-col r))))
      (define st (face-style (run-face r)))
      (emit! (if st (format-styled st (run-text r)) (format-content (run-text r))))))
  ;; 状态栏（最后一行）
  (define p (editor-point (app-ed app)))
  (define status
    (format " ~a  L~a:C~a  ~a   ^Z ^Y  ^G stamp  ^L hl  ^Q quit"
            (app-name app) (add1 (point-line p)) (add1 (point-col p))
            (if (app-highlight? app) "hl:on" "hl:off")))
  (emit! (format-cursor-move (app-rows app) 1))
  (emit! (format-styled 'status-bar (pad-to status (app-cols app))))
  ;; 光标（core 算好屏幕坐标；不可见则隐藏）
  (define cr (screen-cursor-row scr))
  (define cc (screen-cursor-col scr))
  (if (>= cr 0)
      (begin (emit! (format-cursor-move (add1 cr) (add1 cc))) (emit! format-cursor-show))
      (emit! format-cursor-hide))
  (apply bytes-append (reverse parts)))

;;; ============================================================================
;;; §4 事件 → 命令（[前端] 映射；命令本身在 §2）
;;; ============================================================================
;;
;; [core] 事件类型（text/key/mouse/resize/quit）在 core 定义；这里由 racket-tui 的
;;        build-input 分好类，所以只写回调。
;; [前端] 按键 → 命令的映射、Ctrl 组合、鼠标区域判断，都是应用政策。

(define (run path)
  (with-tui
   (lambda ()
     (enable-mouse!)
     (enable-bracketed-paste!)
     (define-values (rows0 cols0) (get-window-size))
     (define app (open-app path (max 2 rows0) (max 1 cols0)))
     (define running? #t)
     (define (redraw) (put-bytes (frame->bytes app)))

     (define handler
       (build-input
        #:text      (lambda (str)  (set! app (insert-text app str)))
        #:enter     (lambda ()     (set! app (newline app)))
        #:backspace (lambda ()     (set! app (delete-back app)))
        #:delete    (lambda ()     (set! app (delete-fwd app)))
        #:tab       (lambda ()     (set! app (insert-text app "  ")))
        #:left      (lambda ()     (set! app (navigate app 'left)))
        #:right     (lambda ()     (set! app (navigate app 'right)))
        #:up        (lambda ()     (set! app (navigate app 'up)))
        #:down      (lambda ()     (set! app (navigate app 'down)))
        #:home      (lambda ()     (set! app (navigate app 'home)))
        #:end       (lambda ()     (set! app (navigate app 'end)))
        #:pageup    (lambda ()     (set! app (navigate app 'pageup)))
        #:pagedown  (lambda ()     (set! app (navigate app 'pagedown)))
        #:escape    (lambda ()     (set! running? #f))
        #:key       (lambda (key mods)
                      (when (and (char? key) (mods-ctrl? mods))
                        (case key
                          [(#\Z) (set! app (undo app))]
                          [(#\Y) (set! app (redo app))]
                          [(#\G) (set! app (append-stamp app))]
                          [(#\L) (set! app (toggle-highlight app))]
                          [(#\Q) (set! running? #f)]
                          [else (void)])))
        #:mouse     (lambda (action button x y _mods)
                      (case action
                        [(press)  (set! app (click app x y))]
                        [(scroll) (set! app (navigate app (if (eq? button 'up) 'pageup 'pagedown)))]
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
  (define a1 (insert-text a0 "abc"))
  (check-equal? (editor-buffer->string (app-ed a1) 0) "abc")
  (check-equal? (editor-point (app-ed a1)) (point 0 3))
  (define a2 (undo a1))
  (check-equal? (editor-buffer->string (app-ed a2) 0) "")

  ;; 自定义 op：自动缩进
  (define a3 (make-app "  x" 5 20 "*t*"))
  (define a4 (navigate a3 'end))
  (define a5 (newline a4))
  (check-equal? (editor-buffer->string (app-ed a5) 0) "  x\n  ")

  ;; 程序面：追加时间戳不改光标
  (define a6 (insert-text (make-app "hi" 5 20 "*t*") "!"))   ; → "!hi"，光标 (0,1)
  (define a7 (append-stamp a6))
  (check-equal? (editor-point (app-ed a7)) (point 0 1))       ; 光标没动（reaction none）
  (check-true (regexp-match? #rx";; stamp" (editor-buffer->string (app-ed a7) 0)))

  ;; 标注：高亮写 face，patch 清旧写新
  (define a8 (insert-text (make-app "" 5 20 "*t*") "define x"))
  (check-equal? (editor-get-property (app-ed a8) 0 (point 0 1) 'face) 'keyword)
  (define a9 (toggle-highlight a8))                            ; 关 → 清掉
  (check-false (editor-get-property (app-ed a9) 0 (point 0 1) 'face))

  ;; 视图面：resize 只改 view，不动文本
  (define a10 (resize a8 8 30))
  (check-equal? (editor-height (app-ed a10)) 7)
  (check-equal? (editor-buffer->string (app-ed a10) 0) "define x")

  (displayln "example.rkt: all tests passed"))

(module+ main
  (define args (current-command-line-arguments))
  (run (and (> (vector-length args) 0) (vector-ref args 0))))

;;; ============================================================================
;;; §6 本示例暴露的 core 改进线索（汇总）
;;; ============================================================================
;;
;; 1. 两个操作面重复：editor-edit（用户面）与 editor-edit-at（程序面）各自实现
;;    「施加→反应→记账→report」。可考虑让 editor-edit-at 收 #:reaction 'leader + vid，
;;    把用户面变成它的特例，消除重复（见 2.1 / 2.5）。
;; 2. 缺少「编辑 + 标注」事务：高亮被迫是第二趟写（tick +2）。可考虑让编辑命令接一个
;;    「变更行区间 → patch」的纯函数，一次完成（见 2.8）。
;; 3. 视图面缺 focus 糖：editor-view-set-size 要自己 (editor-focus) 取 vid；
;;    可补 editor-set-size 之类（见 2.6）。
;; 4. report 粒度偏粗：change-report 只给「首行/末行 + descs」。若前端要按**每个**
;;    变更区间做增量标注（如多光标），需要自己再走 change-report-edits（见 2.0）。
;; 5. editor 面未暴露 marker/overlay：本示例只用 property/patch；要画跨行装饰/诊断
;;    高亮（比如行内波浪线）得下探 buffer-add-overlay，绕开 editor 入口。
