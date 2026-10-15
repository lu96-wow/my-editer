#lang racket

;;; 21 —— 交互式布局 demo（racket-tui with-tui）
;;;
;;;   racket temp/21-interactive-layout.rkt          # 交互（真终端）
;;;   racket temp/21-interactive-layout.rkt check    # headless 自检
;;;
;;; 能力展示：
;;;   C-b          文件树 开 / 关（命令层 keymap）
;;;   鼠标拖接缝   改大小（tree->cuts 命中 → tree-resize-at）
;;;   q / C-x C-c  退出
;;; 树来自声明式 spec；运行期只 show/hide + 拖缝，不动结构。

(require tui
         "../core/editor.rkt"
         "../edit-tui/theme/main.rkt"        ; require 即装样式
         "../edit-tui/core-render/main.rkt"
         "../edit-tui/command/main.rkt"
         "../layout/main.rkt")

;;; ════════════ 状态 ════════════

(define W (box 80))
(define H (box 24))
(define running? (box #t))
(define message (box "C-b 开/关文件树 ｜ 拖接缝改大小 ｜ q 退出"))
(define cache #f)

(define eb (make-buffer "(define (f x)\n  ;; doc\n  (+ x 1))\n\n(f 41)\n" "main.rkt"))
(define ev (buffer-add-view! eb))
(define tb (make-buffer "src/\n  main.rkt\n  util.rkt\n  panel.rkt\nREADME.md" "*tree*"))
(define tv (buffer-add-view! tb))

(define tree (box #f))
(define (base-tree)
  (spec->tree
   (lay 'lr
        (pane 'tree #:view tv #:size 4 #:dock 'left)
        (lay 'tb
             (pane 'editor #:view ev #:size 3 #:dock 'center)
             (pane 'status #:view #f #:size 1 #:dock 'bottom)))))
(set-box! tree (base-tree))

(define (area) (rect 0 0 (unbox W) (unbox H)))
(define (panels) (tree->panels (unbox tree) (area)))

;;; ════════════ 命令层 ════════════

(define (toggle-tree!)
  (set-box! tree (if (tree-visible? (unbox tree) 'tree)
                     (tree-hide (unbox tree) 'tree)
                     (tree-show (unbox tree) 'tree)))
  (set! cache #f)
  (set-box! message (if (tree-visible? (unbox tree) 'tree) "file tree: on" "file tree: off")))

(define keymap
  (keys [(key 'b 'ctrl)          (λ (ctx) (toggle-tree!))]
        [(key 'q)                (λ (ctx) (set-box! running? #f))]
        [(key 'x 'ctrl) (key 'c 'ctrl) (λ (ctx) (set-box! running? #f))]))
(define reader (make-key-reader keymap))

;;; ════════════ 鼠标拖缝 ════════════

(define drag (box #f))

(define (node-at-path t path)
  (for/fold ([n t]) ([i (in-list path)]) (list-ref (split-children n) i)))

;; 按屏幕 (row, col) 开始拖缝：交点可能同时命中竖缝+横缝 → 角拖。
(define (start-drag! row col)
  (define cs (cuts-at (tree->cuts (unbox tree) (area)) row col))
  (when (pair? cs)
    (define descs
      (for/list ([c (in-list cs)])
        (define split (node-at-path (unbox tree) (cut-path c)))
        (define i (cut-index c))
        (list (cut-path c) i (cut-axis c)
              (node-size (list-ref (split-children split) i))
              (node-size (list-ref (split-children split) (add1 i)))
              (cut-before c) (cut-after c))))
    (set-box! drag (list row col descs))
    (set-box! message (format "拖缝（~a）" (map (λ (c) (cut-axis c)) cs)))))

;; 拖到 (row, col)：每条缝按它自己轴上的位移改两侧 size（角拖则两条都动）。
(define (drag-to! row col)
  (define d (unbox drag))
  (when d
    (match-define (list r0 c0 descs) d)
    (for ([desc (in-list descs)])
      (match-define (list path i axis s0 s1 before after) desc)
      (define delta (if (eq? axis 'lr) (- col c0) (- row r0)))
      (define nb (max 1 (+ before delta)))
      (define na (max 1 (- after delta)))
      (set-box! tree (tree-resize-at (unbox tree) path i nb na)))
    (set! cache #f)))

(define (end-drag!) (set-box! drag #f) (set-box! message ""))

;;; ════════════ 绘制 ════════════

(define (status-line)
  (define pend (key-reader-pending-string reader))
  (define s (string-append (if (string=? pend "") "" (format "[~a] " pend)) (unbox message)))
  (define w (unbox W))
  (if (> (string-length s) w) (substring s 0 w) s))

(define (draw!)
  (define p (panels))
  (panels-sync! p)
  (define-values (c r s) (render-display-patch p ev (unbox W) (unbox H) cache))
  (set! cache c)
  (put-bytes (bytes-append (render-clear) (render-pieces (append r s))))
  (put-bytes (format-cursor-move (unbox H) 1))
  (put-string (status-line))
  (flush!))

(define (mouse->rc e) (values (max 0 (sub1 (mouse-event-y e))) (max 0 (sub1 (mouse-event-x e)))))

;;; ════════════ 主循环 ════════════

(define (run-tui!)
  (with-tui
   (λ ()
     (cursor-hide)
     (enable-mouse!)
     (draw!)
     (let loop ()
       (define e (read-event))
       (cond
         [(resize-event? e)
          (set-box! W (resize-event-cols e))
          (set-box! H (resize-event-rows e))
          (set! cache #f)
          (draw!) (loop)]
         [(null-event? e) (loop)]
         [(key-event? e)
          (define-values (st proc) (key-reader-feed! reader e))
          (when (eq? st 'command) (proc '()))
          (draw!)
          (when (unbox running?) (loop))]
         [(mouse-event? e)
          (define-values (row col) (mouse->rc e))
          (case (mouse-event-action e)
            [(press)   (start-drag! row col)]
            [(move)    (drag-to! row col)]
            [(release) (end-drag!)]
            [else (void)])
          (draw!)
          (loop)]
         [else (loop)])))))

;;; ════════════ headless 自检 ════════════

(define (rect-of id) (cadr (assoc id (tree->placements (unbox tree) (area)))))

(define (run-check!)
  (printf "初始：panels=~a  cuts=~a\n" (length (panels))
          (map (λ (c) (list (cut-axis c) (cut-offset c))) (tree->cuts (unbox tree) (area))))
  (define seam-x (rect-x (rect-of 'editor)))
  (define w0 (rect-w (rect-of 'tree)))
  (start-drag! 5 seam-x)
  (drag-to! 5 (+ seam-x 8))          ; 往右拖 8 格
  (end-drag!)
  (printf "拖右 8：tree w ~a → ~a\n" w0 (rect-w (rect-of 'tree)))
  (check (> (rect-w (rect-of 'tree)) w0) "拖右后 tree 变宽")
  ;; 角拖：交点斜拖（右下），两条缝都动
  (define cuts (tree->cuts (unbox tree) (area)))
  (define tbc (car (filter (λ (c) (eq? (cut-axis c) 'tb)) cuts)))
  (define ir (cut-offset tbc))
  (define ic (rect-x (rect-of 'editor)))
  (define e0 (rect-h (rect-of 'editor)))
  (define w1 (rect-w (rect-of 'tree)))
  (start-drag! ir ic)
  (drag-to! (+ ir 3) (+ ic 5))       ; 右下角拖
  (end-drag!)
  (printf "角拖：tree w ~a → ~a，editor h ~a → ~a\n"
          w1 (rect-w (rect-of 'tree)) e0 (rect-h (rect-of 'editor)))
  (check (> (rect-w (rect-of 'tree)) w1) "角拖：tree 变宽")
  (check (> (rect-h (rect-of 'editor)) e0) "角拖：editor 变高")
  (toggle-tree!)                     ; 关
  (printf "关文件树：panels=~a  editor x=~a w=~a\n"
          (length (panels)) (rect-x (rect-of 'editor)) (rect-w (rect-of 'editor)))
  (check (= (length (panels)) 2) "关后只剩 2 块")
  (toggle-tree!)                     ; 开
  (printf "再开：panels=~a  tree w=~a（记忆）\n" (length (panels)) (rect-w (rect-of 'tree)))
  (check (= (length (panels)) 3) "开回来 3 块")
  (displayln "interactive layout demo: 自检 OK"))

(define (check ok? label)
  (if ok? (printf "  ✓ ~a\n" label) (error 'check "~a 失败" label)))

(module+ main
  (if (positive? (vector-length (current-command-line-arguments)))
      (run-check!)
      (run-tui!)))
