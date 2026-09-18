#lang racket

(require "core/api.rkt" "history.rkt" rackunit)

;;; skeleton.rkt —— 用 core 拼出一台编辑器（**骨架，不接前端**）
;;;
;;; 与 main.rkt 的分工：main.rkt 是**完整示范**，它接 racket-tui（raw 模式、按键解码、ANSI 输出）。
;;; 本文件**不 require 任何 io/***，把"用 core 拼编辑器"这件事单独摊开：
;;;
;;;   ① 状态   (struct ed (doc active hist))        —— 只有三样东西
;;;   ② 变换   (handle ed ev) → ed                  —— 唯一输入入口（事件 → 新状态）
;;;   ③ 投影   (render ed) → screen                 —— 唯一输出；后端只需要画它
;;;   ＋ 一个无前端的驱动 (run-script)：把一串事件喂进去、把每帧 screen 打成纯文本
;;;
;;; 前端该做而这里**故意不做**的三件事（排除掉它们，才能看清 core 的用法）：
;;;   1. 把原始输入解码成 core 事件（`text-event` / `key-event`）：io/tui.rkt 干的活；
;;;   2. 把 `screen` 画出去（写 ANSI / 刷终端）：这里只把 screen 的数据摊平打印；
;;;   3. 鼠标屏幕坐标 → (窗口, 行列)：命中哪个窗口是布局知识（`window-screen->point` 负责后半段）。
;;;
;;; ── 这台编辑器用到的 core API（按角色分组；tools/ 可对账）──────────────
;;;   状态与装配   buffer-open make-window document-of-buffer document-add-view
;;;   编辑         buffer-insert-string buffer-newline buffer-backspace buffer-delete
;;;                （**buffer 级 edit-fn 形状** —— 这是 document-edit 的契约形状）
;;;   记账（逆）    document-edit-reversible（逆与「编辑前光标」一次给出；账本在 history.rkt）
;;;   导航/滚动     window-left window-right window-home window-end window-up window-down
;;;                window-scroll window-set-point window-ensure-point
;;;                document-update-view-synced（改视图 + 保持 follow 一致）
;;;   视图管理     document-view-count document-window document-view-sync document-set-view-sync
;;;   撤销/重放     document-apply-edit-trusted（＋ history 消费层的 pop）
;;;   渲染         window->screen screen-compose screen
;;;   纯文本驱动    screen->text screen-cursor-row screen-cursor-col（仅用于打印）
;;;   事件类型     text-event key-event modifiers（这里手搓；真前端负责解码）
;;;
;;; ── 实测：拼一台编辑器用到多少 core？──────────────────────────────
;;; 扫描本文件（去注释后）∩ `core/api.rkt` 白名单：**51 个名字 = 白名单 217 的 24%**
;;; （另加消费层 `history.rkt` 的 10 个）。没用到的 156 个集中在**骨架没实现的功能**：
;;; 属性/语法高亮、只读约束、marker/overlay、patch、鼠标事件、增量绘制
;;; （`screen-diff-rows`）、wrap / 水平滚动细节，以及 `window-*` / `document-*` 的现成编辑
;;; 包装（编辑走「buffer 级 edit-fn + document 漏斗」，所以那些不用）……
;;; 结论：**能编辑、能撤销、能分屏的编辑器，只用到 core 的四分之一。**
;;; ────────────────────────────────────────────────────────────────

;;; ---------- ① 状态：一台编辑器只有三样东西 ----------
;;; doc    : document  文档 + 视图（core 的容器机制：单一事实源 + rebase 模式）
;;; active : nat       哪个视图是"我"（接收编辑/光标的那个）
;;; hist   : history   撤销/重放账本（**消费层** history.rkt；它本身也是用 core 拼的）

(struct ed (doc active hist) #:transparent)

(define (make-editor text [height 8] [width 40] #:views [nviews 1])
  ;; buffer 是文档（无光标）；window 是"怎么看它"（有光标）。
  ;; 两样都装进 document：document 保证所有视图共享同一 buffer。
  (define doc0 (document-of-buffer (buffer-open text)))
  (define-values (doc1 i0) (document-add-view doc0 (make-window height width)))
  (define docn
    (for/fold ([d doc1]) ([i (in-range 1 nviews)])
      (define-values (d* _)
        ;; 第二个视图起用 'follow：编辑视图滚动/移光标时它镜像过去
        (document-add-view d (make-window height width) #:sync 'follow))
      d*))
  (ed docn i0 (make-history)))

(define (active-window a) (document-window (ed-doc a) (ed-active a)))

;;; ---------- ② 变换：三类操作，各自只用一小组 core API ----------

;; 编辑（改**共享文本**）：走 document 的编辑漏斗 → 所有视图按自己的 sync rebase。
;; 逆与「编辑前的光标」由 document-edit-reversible 一并给出（消费者不再自己求逆，
;; §9.3 的静默坑不可达，见 ARCHITECTURE §11.2 ③）。
(define (on-edit a do-edit)
  ;; do-edit 直接用 document-edit 的 edit-fn 形状：(buffer, line, col) → (values buffer desc)
  (define-values (doc* desc inv p0)
    (document-edit-reversible (ed-doc a) (ed-active a) do-edit))
  (if (not desc)
      (struct-copy ed a [doc doc*])                  ; no-op / 被 read-only 拒 → 不入栈
      (struct-copy ed a [doc doc*] [hist (history-record (ed-hist a) desc inv p0)])))

;; 导航/滚动（只动**一个视图**）：改完自动对齐 follow 视图。
;; 视口自洽（top/left 越界）由 document 保证（ARCHITECTURE §10.3 D1），这里不用手动夹。
(define (on-nav a win-fn)
  (struct-copy ed a
    [doc (document-update-view-synced (ed-doc a) (ed-active a) win-fn)]))

;; 撤销/重放：账本给一步（step），把它的 descs 依次**落回视图**，再收光标/同步 follow。
;; trusted 入口：记录在案的编辑当年都过了守卫，不该被事后才加的约束挡住（§9.6）。
(define (on-step a pop)
  (define-values (st h*) (pop (ed-hist a)))
  (cond
    [(not st) a]
    [else
     (define i (ed-active a))
     (define doc* (for/fold ([d (ed-doc a)]) ([x (in-list (step-descs* st))])
                    (define-values (d* _) (document-apply-edit-trusted d i x))
                    d*))
     (struct-copy ed a
       [doc (document-update-view-synced doc* i (step-settle st))]
       [hist h*])]))

;; 撤销用 undo-descs（存成撤销次序）；重放用 replay-descs。
(define (step-descs* st) (step-undo-descs st))
(define (step-settle st) (lambda (w) (window-ensure-point (window-set-point w (step-point st)))))

(define (on-redo a)
  (define-values (st h*) (history-pop-redo (ed-hist a)))
  (cond
    [(not st) a]
    [else
     (struct-copy ed a
       [doc (for/fold ([d (ed-doc a)]) ([x (in-list (step-replay-descs st))])
              (define-values (d* _) (document-apply-edit-trusted d (ed-active a) x))
              d*)]
       [hist h*])]))

;;; ---------- 输入路由：事件 → 上面三类操作 ----------
;;; 真前端在这里之前先把原始输入解码成 core 事件；骨架里的事件是手搓的。

(define (handle a ev)
  (cond
    [(text-event? ev)
     (on-edit a (lambda (b l c) (buffer-insert-string b l c (text-event-text ev))))]
    [(key-event? ev)
     (define k (key-event-key ev))
     (define mods (key-event-modifiers ev))
     (cond
       [(and (char? k) (modifiers-control mods))
        (case (char-downcase k)
          [(#\z) (on-step a history-pop-undo)]
          [(#\y) (on-redo a)]
          [else a])]
       [(symbol? k)
        (case k
          [(enter)     (on-edit a buffer-newline)]
          [(backspace) (on-edit a buffer-backspace)]
          [(delete)    (on-edit a buffer-delete)]
          [(left)      (on-nav a window-left)]
          [(right)     (on-nav a window-right)]
          [(up)        (on-nav a window-up)]
          [(down)      (on-nav a window-down)]
          [(home)      (on-nav a window-home)]
          [(end)       (on-nav a window-end)]
          [else a])]
       [else a])]
    [else a]))

;;; ---------- ③ 投影：状态 → screen（唯一输出）----------
;;; 分屏：每个视图一个 `window->screen`，再用 `screen-compose` 拼成一张大屏；
;;; 底部一条状态行（也是 screen/run，不是前端）。

(define (status-screen a cols)
  (define w (active-window a))
  (define p (window-point w))
  (define text (format "视图 ~a/~a | Ln ~a, Col ~a | 撤销 ~a 重放 ~a"
                       (ed-active a) (sub1 (document-view-count (ed-doc a)))
                       (add1 (point-line p)) (add1 (point-col p))
                       (history-undo-depth (ed-hist a)) (history-redo-depth (ed-hist a))))
  (screen 1 cols (vector (list (run 0 text (hash)))) -1 -1))

(define (render a)
  (define doc (ed-doc a))
  (define n (document-view-count doc))
  (define widths (for/list ([i (in-range n)]) (window-width (document-window doc i))))
  (define area-h (apply max (for/list ([i (in-range n)]) (window-height (document-window doc i)))))
  (define total-w (apply + widths))
  ;; 所有块**一次** compose：视图横向排开（x = 前面各视图宽度之和），状态行压在下面（y = area-h）
  (define pieces
    (append
     (for/list ([i (in-range n)])
       (list i (apply + (take widths i)) 0 (window->screen (document-window doc i))))
     (list (list 'status 0 area-h (status-screen a total-w)))))
  (screen-compose (+ area-h 1) total-w pieces (ed-active a)))

;;; ---------- 无前端驱动：把 screen 摊平（core 的朴素投影 `screen->text`，非前端）----------

(define (run-script a steps)
  (for/fold ([a a]) ([s (in-list steps)])
    (define label (car s))
    (define a* (for/fold ([x a]) ([ev (in-list (cdr s))]) (handle x ev)))
    (displayln (format "\n── ~a" label))
    (displayln (screen->text (render a*)))
    (displayln (format "   光标: row ~a col ~a" (screen-cursor-row (render a*))
                       (screen-cursor-col (render a*))))
    a*))

;;; ---------- 一次无前端的会话（`racket skeleton.rkt`）----------

(module+ main
  (define ctrl-z (key-event #\z (modifiers #t #f #f #f)))
  (define ctrl-y (key-event #\y (modifiers #t #f #f #f)))
  (define (keys . ks) (for/list ([k (in-list ks)]) (key-event k (modifiers #f #f #f #f))))
  (define (texts . ts) (for/list ([t (in-list ts)]) (text-event t (modifiers #f #f #f #f))))

  (displayln "用 core 拼出的编辑器（无前端）：事件手搓，输出只读 screen 的数据")
  (void
   (run-script
    (make-editor "" 4 34)
    (list
     (cons "连打 \"hi\"（两个 text-event 并成**一步**）" (texts "h" "i"))
     (cons "回车 + 打「你好」（又是各自一步）" (texts "\n" "你" "好"))
     (cons "左移一位后插 '!'：光标回退过，**不**与前一段并" (append (keys 'left) (texts "!")))
     (cons "Ctrl+Z：撤掉刚插的 '!'，光标回到插入前" (list ctrl-z))
     (cons "Ctrl+Y：重放" (list ctrl-y))
     (cons "下移到第二行、行尾插入 '?'" (append (keys 'down 'end) (texts "?")))))))

;;; ---------- 测试（这台骨架确实是一台能用的编辑器）----------

(module+ test
  (define (buf a) (document-buffer (ed-doc a)))
  (define (text-of a) (buffer->string (buf a)))
  (define (keys . ks) (for/list ([k (in-list ks)]) (key-event k (modifiers #f #f #f #f))))
  (define (texts . ts) (for/list ([t (in-list ts)]) (text-event t (modifiers #f #f #f #f))))
  (define (feed a evs) (for/fold ([x a]) ([ev (in-list evs)]) (handle x ev)))

  ;; 编辑：插入 / 回车 / 删除
  (define a0 (make-editor "" 6 20))
  (define a1 (feed a0 (texts "a" "b" "\n" "c")))
  (check-equal? (text-of a1) "ab\nc")
  (check-equal? (window-point (active-window a1)) (point 1 1))
  (define a2 (feed a1 (keys 'backspace)))
  (check-equal? (text-of a2) "ab\n")

  ;; 撤销 / 重放：一次 Ctrl+Z 撤掉整段连续打字；一次 Ctrl+Y 放回来
  (check-equal? (history-undo-depth (ed-hist a1)) 3)     ; "ab" 一段 + 回车 + "c"
  (define a3 (feed a1 (list (key-event #\z (modifiers #t #f #f #f)))))
  (check-equal? (text-of a3) "ab\n")
  (check-equal? (history-redo-depth (ed-hist a3)) 1)
  (define a4 (feed a3 (list (key-event #\y (modifiers #t #f #f #f)))))
  (check-equal? (text-of a4) "ab\nc")
  (check-equal? (history-redo-depth (ed-hist a4)) 0)

  ;; 投影：render 出的 screen 尺寸正确、状态行在最底、光标来自 active 视图
  (define s (render a1))
  (check-equal? (screen-rows s) 7)                       ; 6 行 + 状态行
  (check-equal? (screen-cols s) 20)
  (check-true (>= (screen-cursor-row s) 0))
  (check-equal? (run-text (car (vector-ref (screen-row-runs s) 6))) "视图 0/0 | Ln 2, Col 2 | 撤销 3 重放 0")

  ;; 纯文本驱动（非前端）：宽字符按显示列占 2 格
  (define a5 (feed (make-editor "" 4 10) (texts "你" "好")))
  (check-equal? (screen->text (render a5))
                (string-join '("你好" "" "" "" "视图 0/0 | Ln 1, Col 3 | 撤销 1 重放 0") "\n"))

  ;; 两个视图：'follow 视图镜像编辑视图（同一 buffer、光标跟随）
  (define m0 (make-editor "hello" 4 12 #:views 2))
  (check-equal? (document-view-count (ed-doc m0)) 2)
  (check-eq? (document-buffer (ed-doc m0))
             (window-buffer (document-window (ed-doc m0) 1)))
  (define m1 (feed m0 (texts "X")))
  (check-equal? (buffer->string (document-buffer (ed-doc m1))) "Xhello")
  (check-equal? (window-point (document-window (ed-doc m1) 1))
                (window-point (document-window (ed-doc m1) 0)))
  ;; 切 active 视图后，编辑作用在视图 1 上
  (check-equal? (document-view-sync (ed-doc m1) 1) 'follow)

  (displayln "skeleton.rkt: all tests passed"))