#lang racket

(require "core/api.rkt" "io/tui.rkt")

;;; main.rkt —— 两个 window 共享同一 buffer 的编辑器（document 同步演示）
;;;
;;; 这层是「组装层」：core 只给 buffer/window/screen/events/document 原子，
;;; 怎么摆窗口、怎么路由输入、怎么拼屏，全在这里自己写。
;;;
;;;   布局：左窗 + 右窗 + 底部状态行
;;;   同步：左/右两窗是同一 document 的两个视图（view 0 / view 1），
;;;         一个窗打字，另一个实时看到（document-edit 统一 rebase）
;;;   输入：racket-tui raw → core event → handle → active 视图的编辑/导航
;;;   渲染：两个 window->screen → screen-compose → 一张大屏 → ANSI
;;;
;;; 运行：racket main.rkt（需要真实 Linux 终端）
;;; 按键：Tab / Ctrl+O 切窗口；Ctrl+F 切换 active 视图同步策略；Ctrl+Q 退出

;;; ---------- 应用状态：一个 document（两个视图）+ 哪个 active ----------

(struct app (doc active) #:transparent)
;; doc    : document   两个视图共享同一 buffer（单一事实源）
;; active : 0 | 1      当前 active 视图下标

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
  (define-values (doc1 _v0) (document-add-view doc0 (window-open b area-h left-w)  (point 0 2)))
  (define-values (doc2 _v1) (document-add-view doc1 (window-open b area-h right-w) (point 0 2) #:sync 'follow))
  (app doc2 0))

(define (resize-app a rows cols)
  (define-values (area-h left-w right-w) (split-size rows cols))
  (define doc (app-doc a))
  (define doc* (document-update-view doc 0 (lambda (w) (window-set-size w area-h left-w))))
  (define doc** (document-update-view doc* 1 (lambda (w) (window-set-size w area-h right-w))))
  (struct-copy app a [doc doc**]))

(define (status-screen a cols)
  (define w (active-window a))
  (define p (window-point w))
  (define text (format "左[~a] 右[~a] | 视图 ~a | Ln ~a, Col ~a | Tab 切窗 | Ctrl+F 同步 | Ctrl+Q 退出"
                       (sync-name (document-view-sync (app-doc a) 0))
                       (sync-name (document-view-sync (app-doc a) 1))
                       (if (zero? (app-active a)) "左" "右")
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
  (define doc* (document-update-view (app-doc a) (app-active a)
                 (lambda (w) (window-ensure-point (thunk w)))))
  (struct-copy app a
    [doc (document-sync-followers doc* (app-active a))]))

;; 编辑：document-edit 内部已经 ensure-point + 同步 follow，这里只需换 doc
(define (on-edit a do-edit)
  (define-values (doc* _desc) (do-edit (app-doc a) (app-active a)))
  (struct-copy app a [doc doc*]))

(define (handle a ev)
  (cond
    [(quit-event? ev) (values a #t)]
    [(text-event? ev)
     (values (on-edit a (lambda (doc i) (document-insert-string doc i (text-event-text ev)))) #f)]
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
          [else (values a #f)])]
       [else
        (case k
          [(tab)       (values (switch-active a) #f)]
          [(enter)     (values (on-edit a (lambda (doc i) (document-newline doc i))) #f)]
          [(backspace) (values (on-edit a (lambda (doc i) (document-backspace doc i))) #f)]
          [(delete)    (values (on-edit a (lambda (doc i) (document-delete doc i))) #f)]
          [(left)      (values (on-nav a window-left) #f)]
          [(right)     (values (on-nav a window-right) #f)]
          [(up)        (values (on-nav a (lambda (w) (window-visual-move w -1))) #f)]
          [(down)      (values (on-nav a (lambda (w) (window-visual-move w +1))) #f)]
          [(home)      (values (on-nav a window-home) #f)]
          [(end)       (values (on-nav a window-end) #f)]
          [else        (values a #f)])])]
    [(resize-event? ev)
     (values (resize-app a (resize-event-rows ev) (resize-event-cols ev)) #f)]
    [else (values a #f)]))

;;; ---------- 启动 ----------

(module+ main
  (displayln "左右两窗共享同一 buffer：左边打字右边实时同步 | Tab/Ctrl+O 切窗 | Ctrl+Q 退出")
  (tui-run theme make-app render handle))

;;; ---------- 测试（纯函数，不碰终端）----------

(module+ test
  (require rackunit)

  (define a (make-app 10 40))
  (define (w0 a) (document-window (app-doc a) 0))
  (define (w1 a) (document-window (app-doc a) 1))

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
  (check-equal? (buffer-line-ref (window-buffer (w0 a2)) 0) "❯ X输入区 hello 你好")
  (check-equal? (buffer-line-ref (window-buffer (w1 a2)) 0) "❯ X输入区 hello 你好")  ; 右窗同步
  (check-eq? (window-buffer (w0 a2)) (window-buffer (w1 a2)))                        ; 仍不分叉
  (check-equal? (window-point (w0 a2)) (point 0 3))   ; 编辑视图光标推进
  (check-equal? (window-point (w1 a2)) (point 0 3))   ; follow 镜像

  ;; Tab 切到右窗（follow），右窗打字 → 左窗（free）同步内容、但光标不动
  (define-values (a3 _2) (handle a2 (key-event 'tab (modifiers #f #f #f #f))))
  (check-equal? (app-active a3) 1)
  (define-values (a4 _3) (handle a3 (text-event "Y" (modifiers #f #f #f #f))))
  (check-equal? (buffer-line-ref (window-buffer (w1 a4)) 0) "❯ XY输入区 hello 你好")
  (check-equal? (buffer-line-ref (window-buffer (w0 a4)) 0) "❯ XY输入区 hello 你好")  ; 左窗同步
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

  (displayln "main.rkt: all tests passed"))
