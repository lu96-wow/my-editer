#lang racket

;;; edit-tui/layout-base/render.rkt —— 布局 → tui 序列（全量 + 增量）
;;;
;;; 与 core-render/render.rkt 对称：
;;;   core-render/render.rkt   把 core 渲染值（piece）画成 tui 序列 + screen-patch 增量
;;;   layout-base/render.rkt   把布局边框（panel → 格 map）画成 tui 序列 + 格级 diff 增量
;;;
;;; 谁占哪些格、画什么字形、face / deep 都在 border.rkt；这里只做**序列化 / 差量**：
;;;   全量   render-panels         panels → 字节
;;;   增量   render-panels-patch   (旧格 map, panels) → (新格 map, 字节)
;;; 不输出、不 flush。
;;;
;;; 每格 → 光标定位 + face 转义 + 文本 + reset。face 是符号（如 'window-border），
;;; 用 style->bytes 取转义序列（主题在 edit-tui/theme 装）。

(require tui
         "border.rkt")

(provide render-border-run      ; (row col text face deep) -> tui 序列
         render-border-runs     ; (listof run) -> tui 序列
         render-border-cells    ; cells -> tui 序列（按行合并）
         render-panels          ; (listof panel) -> tui 序列（全量）
         render-panels-patch)   ; old-cells (listof panel) -> (values new-cells tui 序列)（增量）

;; 序列拼接（滤掉 #f；tui 拼 bytes）。内部工具，不外露。
(define (fragment . parts) (apply bytes-append (filter values parts)))

;; 一段 border-run -> 序列。
(define (render-border-run b)
  (match-define (list row col text face _deep) b)
  (fragment
   (format-cursor-move (add1 row) (add1 col))    ; 1-based
   (and face (style->bytes face))
   (format-content text)
   format-reset))

(define (render-border-runs bs)
  (apply fragment (map render-border-run bs)))

;; 一批格 -> 序列（先按行合并同 deep / 同 face 的相邻格）。
(define (render-border-cells cells)
  (render-border-runs (border-cells->runs cells)))

;;; ---------- 全量 ----------

;; 面板布局 -> 边框序列。run 已在 border.rkt 里按 deep 定过归属、互不重叠。
(define (render-panels ps)
  (render-border-cells (panels->border-cells ps)))

;;; ---------- 增量 ----------

;; (旧格 map, panels) -> (values 新格 map 差分序列)。
;; 与 core 的 render-display-patch 对称：宿主保存返回的新格 map，下一帧当 old 传回。
;;   变化的格  -> 画新字形
;;   消失的格  -> 画空格（face #f）清掉旧框（框移动 / 关闭时）
;; 只有字形 / face 变了才算变（deep 只影响跟内容合成，不影响直接输出）。
(define (render-panels-patch old ps)
  (define new (panels->border-cells ps))
  (values new (render-border-cells (border-cells-diff old new))))

(define (same-output? a b)
  (and a (eqv? (car a) (car b)) (equal? (cadr a) (cadr b))))

;; 变化格 + 消失格（空格）→ 新格 map。
(define (border-cells-diff old new)
  (define changed (make-hash))
  (for ([(cell gfd) (in-hash new)])
    (unless (same-output? (and old (hash-ref old cell #f)) gfd)
      (hash-set! changed cell gfd)))
  (when old
    (for ([(cell _) (in-hash old)])
      (unless (hash-has-key? new cell)
        (hash-set! changed cell (list #\space #f 0)))))
  changed)

(module+ test
  (require rackunit "rect.rkt" "panel.rkt")
  (define (p x) (make-panel 'a (rect x 0 4 3) borders-all))

  ;; 全量：非空、含字形
  (define bs (render-panels (list (p 0))))
  (check-true (bytes? bs))
  (check-true (regexp-match? #rx"┌" (bytes->string/utf-8 bs)))

  ;; 增量：首帧（old = #f）
  (define-values (c1 b1) (render-panels-patch #f (list (p 0))))
  (check-true (> (bytes-length b1) 0))

  ;; 没变 → 无输出
  (define-values (c2 b2) (render-panels-patch c1 (list (p 0))))
  (check-equal? (bytes-length b2) 0)

  ;; 右移 → 有变化：新位置重画 + 旧位置空格清除
  (define-values (c3 b3) (render-panels-patch c1 (list (p 5))))
  (check-true (> (bytes-length b3) 0))
  (check-true (regexp-match? #rx" " (bytes->string/utf-8 b3)))   ; 清除旧框

  (displayln "layout-base/render.rkt: ok"))
