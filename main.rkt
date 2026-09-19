#lang racket

(require "core/api.rkt" "history.rkt" "io/tui.rkt")

;;; main.rkt —— 两个 window 共享同一 buffer 的编辑器（document 同步演示）
;;;
;;; 这层是「组装层」：core 只给 buffer/window/screen/events/document 原子，
;;; 怎么摆窗口、怎么路由输入、怎么拼屏，全在这里自己写。
;;; 撤销/重放的账本也属于组装层（history.rkt）——core 只提供逆编辑代数，见 ARCHITECTURE §8.5。
;;;
;;;   布局：左窗 + 右窗 + 底部状态行
;;;   同步：左/右两窗是同一 document 的两个视图（view 0 / view 1），
;;;         一个窗打字，另一个实时看到（document-edit 统一 rebase）
;;;   输入：racket-tui raw → core event → handle → active 视图的编辑/导航
;;;   撤销：每次编辑经 on-edit 记一步（逆在编辑时捕获）；连续打字 / 连续删除并成一步
;;;   渲染：两个 window->screen → screen-compose → 一张大屏 → ANSI
;;;
;;; 运行：racket main.rkt（需要真实 Linux 终端）
;;; 按键：Tab / Ctrl+O 切窗口；Ctrl+Z 撤销、Ctrl+Y 重放；
;;;       Ctrl+F 切换 active 视图同步策略；Ctrl+Q 退出

;;; ---------- 应用状态：一个 document（两个视图）+ 哪个 active + 撤销账本 ----------

(struct app (doc active hist) #:transparent)
;; doc    : document   两个视图共享同一 buffer（单一事实源）
;; active : 0 | 1      当前 active 视图下标
;; hist   : history    撤销/重放账本（消费层，见 history.rkt）

(define (active-window a)
  (document-window (app-doc a) (app-active a)))

(define (switch-active a)
  (struct-copy app a [active (- 1 (app-active a))]))

;; 同步策略显示名 + 切换（free ↔ follow）
(define (sync-name s) (if (eq? s 'follow) "follow" "free"))

(define (cycle-sync a)
  (define i (app-active a))
  (define cur (document-view-sync (app-doc a) i))
  (define next (if (eq? cur 'follow) 'free 'follow))
  (struct-copy app a [doc (document-set-view-sync (app-doc a) i next)]))

;;; ---------- 示例内容（单一 buffer，两个视图共享）----------
;;; 第 0 行的 "❯ " 是 read-only 提示，在两个窗口里都不可编辑

(define sample
  (string-join
   '("❯ 输入区 hello 你好"
     "(define (square x) (* x x))"
     "(define msg \"hello 😀\") ; 字符串"
     ""
     "(cond [(> x 0) 'pos] [else 'neg])")
   "\n"))

;;; ---------- 一次性语法高亮（属性写进 buffer，之后自动流进 screen）----------

(define keyword-rx #px"\\b(define|lambda|if|cond|let|for|match|and|or|not|else)\\b")
(define string-rx  #px"\"[^\"]*\"")
(define comment-rx #px";[^\n]*")

(define (matches->segs line rx face text)
  (for/list ([m (in-list (regexp-match-positions* rx text))])
    (list line (car m) (cdr m) 'face face)))

(define (highlight b)
  (buffer-put-properties-many
   b
   (apply append
          (for/list ([line (in-range (buffer-line-count b))])
            (define text (buffer-line-ref b line))
            (append (matches->segs line keyword-rx 'keyword text)
                    (matches->segs line string-rx  'string  text)
                    (matches->segs line comment-rx 'comment text))))))

;; 把第 0 行的 "❯ "（[0,2)）标成 read-only 提示（不可编辑 + 提示色）。
;; 注意：这是 buffer 级属性，所以两个视图里都 read-only —— 共享文档的自然结果。
(define (mark-prompt b)
  (buffer-put-restrict
   (buffer-put-properties-many b (list (list 0 0 2 'face 'prompt)))
   0 0 2 (restrict #t)))

;;; ---------- 主题（face → 中性样式，后端翻译）----------

(define theme
  (hash 'keyword '(97 175 239)    ; 蓝
        'string  '(152 195 121)   ; 绿
        'comment '(128 128 128)   ; 灰
        'prompt  '(229 192 123)   ; 黄（read-only 提示）
        'mode    '(92 99 112)))   ; 灰（状态行）

;;; ---------- 布局：左右分屏 + 状态行 ----------

(define (split-size rows cols)
  (define area-h (max 1 (- rows 1)))
  (define left-w (max 1 (quotient cols 2)))
  (define right-w (max 1 (- cols left-w)))
  (values area-h left-w right-w))

;; 按显示宽度截断到 max-cols（宽字符占 2 列），保证放进状态行不折行
(define (fit-width text max-cols)
  (let loop ([i 0] [w 0])
    (cond
      [(>= i (string-length text)) text]
      [else
       (define cw (char-display-width (string-ref text i)))
       (if (> (+ w cw) max-cols)
           (substring text 0 i)
           (loop (add1 i) (+ w cw)))])))

(define (make-app rows cols)
  (define-values (area-h left-w right-w) (split-size rows cols))
  (define b (mark-prompt (highlight (buffer-open sample))))
  (define doc0 (document-of-buffer b))
  ;; 两个视图共享 b；左 'free（参考视图），右 'follow（跟手），光标都在提示后
  (define-values (doc1 _v0) (document-add-view doc0 area-h left-w (point 0 2)))
  (define-values (doc2 _v1) (document-add-view doc1 area-h right-w (point 0 2) #:sync 'follow))
  (app doc2 0 (make-history)))

(define (resize-app a rows cols)
  (define-values (area-h left-w right-w) (split-size rows cols))
  (define doc (app-doc a))
  (define doc* (document-update-view doc 0 (lambda (w) (window-set-size w area-h left-w))))
  (define doc** (document-update-view doc* 1 (lambda (w) (window-set-size w area-h right-w))))
  (struct-copy app a [doc doc**]))

(define (status-screen a cols)
  (define w (active-window a))
  (define p (window-point w))
  (define text (format "左[~a] 右[~a] | 视图 ~a | 撤销 ~a 重放 ~a | Ln ~a, Col ~a | Tab 切窗 | Ctrl+Z/Y | Ctrl+F 同步 | Ctrl+Q 退出"
                       (sync-name (document-view-sync (app-doc a) 0))
                       (sync-name (document-view-sync (app-doc a) 1))
                       (if (zero? (app-active a)) "左" "右")
                       (history-undo-depth (app-hist a))
                       (history-redo-depth (app-hist a))
                       (add1 (point-line p))
                       (add1 (point-col p))))
  ;; 按显示宽度截断（宽字符占 2 列）。绝不能用 substring 按字符数截——
  ;; 状态栏文本含中文，字符数 != 显示列数，溢出会折行并让终端整体上滚。
  (define shown (fit-width text cols))
  (screen 1 cols (vector (list (run 0 shown (hash 'face 'mode)))) -1 -1))

;;; ---------- 渲染：两个视图 → compose 成一张大屏 ----------

(define (render a)
  (define doc (app-doc a))
  (define w0 (document-window doc 0))
  (define w1 (document-window doc 1))
  (define area-h (window-height w0))
  (define left-w (window-width w0))
  (define total-w (+ left-w (window-width w1)))
  (screen-compose
   (+ area-h 1) total-w
   (list (list 'left   0      0    (window->screen w0))
         (list 'right  left-w 0    (window->screen w1))
         (list 'status 0      area-h (status-screen a total-w)))
   (if (zero? (app-active a)) 'left 'right)))   ; 光标来自 active 视图

;;; ---------- 命令层：event → active 视图的编辑/导航 ----------

;; 导航（只动 active 视图的 window，然后把 active 的最终视口对齐到 follow 视图）
(define (on-nav a thunk)
  (struct-copy app a
    [doc (document-update-view (app-doc a) (app-active a)
           (lambda (w) (window-ensure-point (thunk w))))]))

;; 编辑：document-edit 内部已经 ensure-point + 同步 follow，这里只需换 doc + 记一步撤回。
;; 一次编辑的完整材料（desc / inv / 编辑前光标）由它一并给出——要不要撤销只改变你对
;; 第二值的处理；§8.5 那个静默坑（用后态 buffer 求逆不报错）不可达。
(define (on-edit a do-edit)
  ;; do-edit 直接用 document-edit 的 edit-fn 形状：(buffer, line, col) → (values buffer desc)。
  (define-values (doc* ch) (document-edit (app-doc a) (app-active a) do-edit))
  (struct-copy app a
    [doc doc*]
    ;; no-op / 被 read-only 拒 → 整个 change 是 #f → 不入栈
    [hist (if ch (history-record (app-hist a) ch) (app-hist a))]))

;;; ---------- 撤销 / 重放（账本在 history.rkt；落回必须经 document）----------

;; 撤销一步：该步的逆 desc 依次落回，再把光标放回该步**之前**的位置，follow 视图随之对齐。
;; 落回入口一次做完这两件事（trusted：记录在案的编辑当年都过了守卫，§8.5）。
(define (on-undo a)
  (define-values (st h*) (history-pop-undo (app-hist a)))
  (if st
      (struct-copy app a
        [doc (document-apply-descs-trusted (app-doc a) (app-active a)
                                           (step-undo-descs st) (step-point st))]
        [hist h*])
      a))                                            ; 空栈：什么都不做

;; 重放一步：原 desc 依次落回；光标由最后一条 desc 落脚（= 该步之后的位置，与原来一致）。
(define (on-redo a)
  (define-values (st h*) (history-pop-redo (app-hist a)))
  (if st
      (struct-copy app a
        [doc (document-apply-descs-trusted (app-doc a) (app-active a)
                                           (step-replay-descs st))]
        [hist h*])
      a))

(define (handle a ev)
  (cond
    [(quit-event? ev) (values a #t)]
    [(text-event? ev)
     (values (on-edit a (edit-insert (text-event-text ev))) #f)]
    [(key-event? ev)
     (define k (key-event-key ev))
     (define mods (key-event-modifiers ev))
     (cond
       ;; 字符键 = Ctrl+字符（普通字符走 text-event）
       [(char? k)
        (cond
          [(and (modifiers-control mods) (char-ci=? k #\q)) (values a #t)]
          [(and (modifiers-control mods) (char-ci=? k #\o)) (values (switch-active a) #f)]
          [(and (modifiers-control mods) (char-ci=? k #\f)) (values (cycle-sync a) #f)]
          [(and (modifiers-control mods) (char-ci=? k #\z)) (values (on-undo a) #f)]
          [(and (modifiers-control mods) (char-ci=? k #\y)) (values (on-redo a) #f)]
          [else (values a #f)])]
       [else
        (case k
          [(tab)       (values (switch-active a) #f)]
          [(enter)     (values (on-edit a (edit-newline)) #f)]
          [(backspace) (values (on-edit a (edit-backspace)) #f)]
          [(delete)    (values (on-edit a (edit-delete)) #f)]
          [(left)      (values (on-nav a window-left) #f)]
          [(right)     (values (on-nav a window-right) #f)]
          [(up)        (values (on-nav a window-up) #f)]
          [(down)      (values (on-nav a window-down) #f)]
          [(home)      (values (on-nav a window-home) #f)]
          [(end)       (values (on-nav a window-end) #f)]
          [else        (values a #f)])])]
    [(resize-event? ev)
     (values (resize-app a (resize-event-rows ev) (resize-event-cols ev)) #f)]
    [else (values a #f)]))

;;; ---------- 启动 ----------

(module+ main
  (displayln "左右两窗共享同一 buffer：左边打字右边实时同步 | Tab/Ctrl+O 切窗 | Ctrl+Z 撤销 / Ctrl+Y 重放 | Ctrl+Q 退出")
  (tui-run theme make-app render handle))

;;; ---------- 测试（纯函数，不碰终端）----------

(module+ test
  (require rackunit)

  (define a (make-app 10 40))
  (define (w0 a) (document-window (app-doc a) 0))
  (define (w1 a) (document-window (app-doc a) 1))
  (define (line0 ap) (list-ref (document->lines (app-doc ap)) 0))   ; 读文本走 document 层（§8.6）

  ;; 布局：左右各 20 列，高 9（10-1 状态行）
  (check-equal? (window-width (w0 a)) 20)
  (check-equal? (window-width (w1 a)) 20)
  (check-equal? (window-height (w0 a)) 9)

  ;; 渲染：buffer 区 + 状态行 = 10 行，40 列
  (define s (render a))
  (check-equal? (screen-rows s) 10)
  (check-equal? (screen-cols s) 40)

  ;; 关键：两视图共享同一 buffer（不分叉）；策略默认左 free / 右 follow
  (check-eq? (window-buffer (w0 a)) (window-buffer (w1 a)))
  (check-equal? (window-point (w0 a)) (point 0 2))
  (check-equal? (window-point (w1 a)) (point 0 2))
  (check-equal? (document-view-sync (app-doc a) 0) 'free)
  (check-equal? (document-view-sync (app-doc a) 1) 'follow)

  ;; read-only 提示是 buffer 级约束 → 两个视图里都不可编辑
  (check-true (buffer-read-only-at? (window-buffer (w0 a)) 0 1))
  (check-equal? (buffer-get-property (window-buffer (w1 a)) 0 1 'face) 'prompt)

  ;; 核心同步：左窗打字 → 右窗（同一 buffer）实时看到；右窗 follow 镜像左窗光标
  (define-values (a2 _1) (handle a (text-event "X" (modifiers #f #f #f #f))))
  (check-equal? (line0 a2) "❯ X输入区 hello 你好")
  (check-equal? (line0 a2) "❯ X输入区 hello 你好")  ; 右窗同步（同一 buffer）
  (check-eq? (window-buffer (w0 a2)) (window-buffer (w1 a2)))                        ; 仍不分叉
  (check-equal? (window-point (w0 a2)) (point 0 3))   ; 编辑视图光标推进
  (check-equal? (window-point (w1 a2)) (point 0 3))   ; follow 镜像

  ;; Tab 切到右窗（follow），右窗打字 → 左窗（free）同步内容、但光标不动
  (define-values (a3 _2) (handle a2 (key-event 'tab (modifiers #f #f #f #f))))
  (check-equal? (app-active a3) 1)
  (define-values (a4 _3) (handle a3 (text-event "Y" (modifiers #f #f #f #f))))
  (check-equal? (line0 a4) "❯ XY输入区 hello 你好")
  (check-equal? (line0 a4) "❯ XY输入区 hello 你好")  ; 左窗同步（同一 buffer）
  (check-eq? (window-buffer (w0 a4)) (window-buffer (w1 a4)))
  (check-equal? (window-point (w1 a4)) (point 0 4))   ; 右窗（编辑）光标推进
  (check-equal? (window-point (w0 a4)) (point 0 3))   ; 左窗（free）光标不动

  ;; Ctrl+F 切换 active（右窗）策略 follow → free
  (define-values (a5 _4) (handle a4 (key-event #\f (modifiers #t #f #f #f))))
  (check-equal? (document-view-sync (app-doc a5) 1) 'free)
  (check-equal? (document-view-sync (app-doc a5) 0) 'free)   ; 左窗不变

  ;; 光标来自 active 视图：切到右窗后，屏幕光标落在右半（x ≥ 20）
  (define s4 (render a4))
  (check-true (>= (screen-cursor-col s4) 20))

  ;; Ctrl+Q → done
  (define-values (_w done?) (handle a (key-event #\q (modifiers #t #f #f #f))))
  (check-true done?)

  ;; ---- 撤销 / 重放（端到端；账本在 history.rkt）----
  (define ctrl-z (key-event #\z (modifiers #t #f #f #f)))
  (define ctrl-y (key-event #\y (modifiers #t #f #f #f)))

  ;; 连续打字 = 一步（段合并）
  (define ua (make-app 10 40))
  (define-values (u1 _u1) (handle ua (text-event "X" (modifiers #f #f #f #f))))
  (define-values (u2 _u2) (handle u1 (text-event "Y" (modifiers #f #f #f #f))))
  (check-equal? (line0 u2) "❯ XY输入区 hello 你好")
  (check-equal? (history-undo-depth (app-hist u2)) 1)
  (check-equal? (window-point (w0 u2)) (point 0 4))       ; 编辑视图光标在插入后
  (check-equal? (window-point (w1 u2)) (point 0 4))       ; follow 视图镜像

  ;; Ctrl+Z → 一次撤到底，光标回到该步**之前**的位置，follow 视图跟上
  (define-values (u3 _u3) (handle u2 ctrl-z))
  (check-equal? (line0 u3) "❯ 输入区 hello 你好")
  (check-equal? (window-point (w0 u3)) (point 0 2))
  (check-equal? (window-point (w1 u3)) (point 0 2))
  (check-equal? (history-undo-depth (app-hist u3)) 0)
  (check-equal? (history-redo-depth (app-hist u3)) 1)

  ;; Ctrl+Y → 重放，光标回到插入之后
  (define-values (u4 _u4) (handle u3 ctrl-y))
  (check-equal? (line0 u4) "❯ XY输入区 hello 你好")
  (check-equal? (window-point (w0 u4)) (point 0 4))
  (check-equal? (history-undo-depth (app-hist u4)) 1)
  (check-equal? (history-redo-depth (app-hist u4)) 0)

  ;; 撤销后新编辑 → redo 栈清空（分叉丢弃）
  (define-values (u5 _u5) (handle u4 ctrl-z))
  (define-values (u6 _u6) (handle u5 (text-event "Z" (modifiers #f #f #f #f))))
  (check-equal? (line0 u6) "❯ Z输入区 hello 你好")
  (check-equal? (history-redo-depth (app-hist u6)) 0)

  ;; 空栈：Ctrl+Z / Ctrl+Y 什么都不做
  (define ue (make-app 10 40))
  (define-values (ue1 _ue1) (handle ue ctrl-z))
  (check-equal? (line0 ue1) "❯ 输入区 hello 你好")
  (check-false (history-can-undo? (app-hist ue1)))
  (define-values (ue2 _ue2) (handle ue ctrl-y))
  (check-false (history-can-redo? (app-hist ue2)))

  ;; 被 read-only 拒绝的编辑不入栈（提示区 [0,2) 内打字 → no-op）
  (define ra (make-app 10 40))
  (define ra1 (struct-copy app ra
                [doc (document-update-view (app-doc ra) 0
                       (lambda (w) (window-set-point w (point 0 1))))]))
  (define-values (ra2 _ra2) (handle ra1 (text-event "N" (modifiers #f #f #f #f))))
  (check-equal? (line0 ra2) "❯ 输入区 hello 你好")
  (check-equal? (history-undo-depth (app-hist ra2)) 0)

  ;; 删除也记一步：退格删掉 (0,2) 的「输」→ 撤销回原样
  (define da (make-app 10 40))
  (define da1 (struct-copy app da
                [doc (document-update-view (app-doc da) 0
                       (lambda (w) (window-set-point w (point 0 3))))]))
  (define-values (da2 _da2) (handle da1 (key-event 'backspace (modifiers #f #f #f #f))))
  (check-equal? (line0 da2) "❯ 入区 hello 你好")
  (check-equal? (history-undo-depth (app-hist da2)) 1)
  (define-values (da3 _da3) (handle da2 ctrl-z))
  (check-equal? (line0 da3) "❯ 输入区 hello 你好")
  (check-equal? (window-point (w0 da3)) (point 0 3))       ; 回到退格前的位置

  (displayln "main.rkt: all tests passed"))
