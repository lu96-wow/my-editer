#lang racket

(require "../../../core/text/base/line.rkt"
         "../../base/face.rkt"
         "../../config/syntax.rkt"
         "api.rkt"
         "lex.rkt")

;;; lab-rebuild/plugin/attr/syntax.rkt —— Racket 关键字高亮（内置属性插件）
;;;
;;; 只对 Racket 源文件生效（扩展名 / 关键字表在 config/syntax.rkt，可配置）。
;;; 每个关键字用**固定颜色**：按它在 keyword-list 里的位置取色号 →
;;; face = (palette-color 'keyword 位置)，颜色由主题 'keyword 色板决定。
;;; 位置固定 ⇒ 同一个关键字任何时候都是同一个颜色；相邻关键字拿相邻色号，颜色不挨着。
;;;
;;; 输入不闪：和词着色一样，**跳过正在输入的那个词**（活动词）——
;;; 否则打 `for` 会先上色、再加 `m`（→ `format`）又掉色；打 `define` 时也是。
;;; 等词“定下来”（敲分隔符 / 移开）才上色。
;;;
;;; 注册在词着色插件**之后** → 关键字层盖在词色上（主题逐分量合并）。
;;; 无状态：open/change 都整篇重扫。

(provide syntax-plugin)

;; 关键字 → 固定色号
(define keyword-index
  (for/hash ([k (in-list keyword-list)] [i (in-naturals)]) (values k i)))

(define (syntax-fills text skip)
  (for/list ([tok (in-list (scan-words text))]
             #:when (and (hash-has-key? keyword-index (cadddr tok))
                         (not (and skip (= (car tok) (car skip)) (= (cadr tok) (cadr skip))))))
    (match-define (list ln s e w) tok)
    (list ln s ln e (palette-color 'keyword (hash-ref keyword-index w)))))

(define (syntax-open text path)
  (values #f (if (racket-file? path) (syntax-fills text #f) '())))

(define (syntax-change _state edits lines path)
  (values #f (if (racket-file? path)
                 (syntax-fills (lines->string (vector->list lines)) (active-token lines edits))
                 '())))

(define syntax-plugin
  (plugin 'syntax syntax-open syntax-change))
