#lang racket

(require "../atom/point.rkt" "../atom/selection.rkt" "../atom/width.rkt"
         "../doc/buffer.rkt" "../doc/document.rkt" "window.rkt" "../unit/screen.rkt" "layout.rkt" "render.rkt"
         rackunit)

;;; viewport/project.rkt —— 把 窗口 的可见区投影成 屏幕（纯函数）
;;;
;;; 两条通道分开投影：
;;;   文档文本   窗口-虚拟行集 → 行范围->片段集 → 屏行-片段集
;;;   视图 覆盖层  窗口-选区列表 → 光标点（头部）/ 选中区段（[锚点,头部) 按 虚拟行 切）
;;; 真正的绘制在后端；这里只给屏幕坐标 + 语义 外观。

(provide 窗口->屏幕)

;; 一个选区在**某一行**的显示列区间 (list 起点 末尾)，不在该行 → #f。
(define (选区-范围-开-行 b sl sc el ec 行)
  (define 文本 (缓冲-行-引用 b 行))
  (cond
    [(and (= 行 sl) (= 行 el)) (list (索引->显示列 文本 sc) (索引->显示列 文本 ec))]
    [(= 行 sl)                   (list (索引->显示列 文本 sc) (字符串-显示-宽度 文本))]
    [(= 行 el)                   (list 0 (索引->显示列 文本 ec))]
    [(and (> 行 sl) (< 行 el)) (list 0 (字符串-显示-宽度 文本))]
    [else #f]))

;; 一个选区 → 若干屏幕区间段（每个可见 虚拟行 至多一段）。空选区 → '()。
;; 虚拟行集 由调用方传入（一次算好，不在每个选区里重建）。
(define (选区->区域集 w 虚拟行集 sel)
  (define b (窗口-缓冲 w))
  (define-values (s e) (选区-范围 sel))
  (define sl (位置-行 s)) (define sc (位置-列 s))
  (define el (位置-行 e)) (define ec (位置-列 e))
  (for/list ([vr (in-vector 虚拟行集)] [屏行 (in-naturals)])
    (define ln (虚拟行-行 vr))
    (define rng (and (>= ln 0) (选区-范围-开-行 b sl sc el ec ln)))
    (if rng
        (let* ([a (car rng)] [z (cadr rng)]
               [s* (max a (虚拟行-起点-列 vr))]
               [e* (min z (虚拟行-末尾-列 vr))])
          (and (< s* e*)
               (区域 屏行 (- s* (虚拟行-起点-列 vr)) (- e* (虚拟行-起点-列 vr))
                       (hash '外观 '选区))))
        #f)))

(define (窗口->屏幕 w [外观-提供者 空外观提供者])
  (define b (窗口-缓冲 w))
  (define 虚拟行集 (窗口-虚拟行集 w))
  (define g (窗口-边栏-宽度 w))
  ;; 折行 下同一行会占多个 虚拟行；整行 字形 只渲染一次，各段复用（否则每个 虚拟行 重渲整行）。
  (define 字形-缓存 (make-hash))
  (define (字形集-用于 li)
    (hash-ref! 字形-缓存 li
               (lambda () (已渲染-行-字形集 (渲染-行 b li 外观-提供者)))))
  (define 屏行-片段集
    (for/vector ([vr (in-vector 虚拟行集)] [屏行 (in-naturals)])
      (define 内容
        (if (and (>= (虚拟行-行 vr) 0) (< (虚拟行-起点-列 vr) (虚拟行-末尾-列 vr)))
            (行范围->片段集/字形集 (字形集-用于 (虚拟行-行 vr))
                                     (虚拟行-起点-列 vr) (虚拟行-末尾-列 vr))
            '()))
      (define 边栏
        (cond
          [(zero? g) '()]
          [(and (>= (虚拟行-行 vr) 0) (虚拟行-行的首段? 虚拟行集 屏行))
           (list (行号片段 (add1 (虚拟行-行 vr)) g))]
          [else (list (空白-边栏-片段 g))]))
      (append 边栏 (map (lambda (rn) (平移-片段 rn g)) 内容))))
  ;; 视图 覆盖层：光标 = 每个选区的 头部（列 +g → 屏幕绝对列）
  (define 光标列表
    (filter values
            (for/list ([s (in-list (窗口-选区列表 w))] [i (in-naturals)])
              (define-values (r c) (窗口-位置->屏幕/虚拟行集 w 虚拟行集 (选区-位置 s)))
              (and r (光标 r (+ g c) (hash '外观 '光标) (= i (窗口-主选区-索引 w)))))))
  ;; 视图 覆盖层：选中区 = 每个非空选区的 [锚点,头部)
  (define 选区列表
    (for/list ([rg (in-list (filter values (append* (for/list ([s (in-list (窗口-选区列表 w))])
                                                      (选区->区域集 w 虚拟行集 s))))) ])
      (区域 (区域-屏行 rg) (+ g (区域-起点-列 rg)) (+ g (区域-末尾-列 rg)) (区域-外观 rg))))
  (屏幕 (窗口-高度 w) (窗口-宽度 w) 屏行-片段集 光标列表 选区列表))

;;; ---------- 行号栏（视图装饰，不属文档） ----------

;; 该 虚拟行 是否是它那条 缓冲 行的首段（折行 下只有首段显示行号）。
(define (虚拟行-行的首段? 虚拟行集 屏行)
  (or (= 屏行 0)
      (not (= (虚拟行-行 (vector-ref 虚拟行集 屏行))
              (虚拟行-行 (vector-ref 虚拟行集 (sub1 屏行)))))))

;; 行号栏一格：**恰好占 g 显示列** —— 数字右对齐到左侧 g-1 列 + 1 列分隔空格；列 固定 0。
;; g 可能因「栏不得吃掉全部列」被夹到比数字位数还小；此时保留**低位**数字，绝不溢出负宽。
(define (行号片段 n g)
  (define s (number->string n))
  (define 数量-列数 (max 0 (sub1 g)))
  (define 已显示 (if (>= (string-length s) 数量-列数)
                    (substring s (- (string-length s) 数量-列数))
                    s))
  (片段 0 (string-append (make-string (- 数量-列数 (string-length 已显示)) #\space) 已显示 " ")
       (hash '外观 '行号)))
(define (空白-边栏-片段 g) (片段 0 (make-string g #\space) (hash '外观 '行号)))
(define (平移-片段 rn x) (片段 (+ x (片段-列 rn)) (片段-文本 rn) (片段-外观 rn)))

;;; ---------- 测试 ----------

(module+ test
  (define b0 (文档-打开 "a中b\nc"))

  ;; 基本投影：文档 片段集 + 主选区 光标；空选区不出区间
  (define s0 (窗口->屏幕 (窗口-打开 b0 2 10)))
  (check-equal? (屏幕-屏行 s0 0) (list (片段 0 "a中b" #f)))
  (check-equal? (屏幕-屏行 s0 1) (list (片段 0 "c" #f)))
  (check-equal? (屏幕-光标-屏行 s0) 0)
  (check-equal? (屏幕-光标-列 s0) 0)
  (check-equal? (map (lambda (c) (list (光标-屏行 c) (光标-列 c) (光标-主选区? c))) (屏幕-光标列表 s0))
                '((0 0 #t)))
  (check-equal? (屏幕-选区列表 s0) '())                    ; 空选区不出区间

  ;; 光标显示列
  (check-equal? (屏幕-光标-列 (窗口->屏幕 (窗口-设置-位置 (窗口-打开 b0 2 10) (位置 0 2)))) 3)

  ;; 选中区：跨宽字符 → 显示列区间；另一行是空光标
  (define ws (窗口-打开 (文档-打开 "abcdef\nghij") 3 10))
  (define wsel (窗口-设置-选区列表 ws (list (选区 (位置 0 1) (位置 0 4))
                                               (选区 (位置 1 0) (位置 1 2)))))
  (define ss (窗口->屏幕 wsel))
  (check-equal? (map (lambda (c) (list (光标-屏行 c) (光标-列 c) (光标-主选区? c))) (屏幕-光标列表 ss))
                '((0 4 #t) (1 2 #f)))
  (check-equal? (map (lambda (g) (list (区域-屏行 g) (区域-起点-列 g) (区域-末尾-列 g)))
                     (屏幕-选区列表 ss))
                '((0 1 4) (1 0 2)))

  ;; 折行：一行折成两段，选中区切成两段
  (define ww (窗口-设置-模式 (窗口-设置-选区列表 (窗口-打开 (文档-打开 "中中中") 3 4)
                                                     (list (选区 (位置 0 0) (位置 0 3))))
                              '折行))
  (check-equal? (map (lambda (g) (list (区域-屏行 g) (区域-起点-列 g) (区域-末尾-列 g)))
                     (屏幕-选区列表 (窗口->屏幕 ww)))
                '((0 0 4) (1 0 2)))                          ; "中中" + "中"

  ;; 派生 外观 分段（投影 提供者，不进文档）
  (define (提供者 _b 行) (if (zero? 行) (list (list 0 1 (hash '外观 '粗体))) '()))
  (check-equal? (屏幕-屏行 (窗口->屏幕 (窗口-打开 b0 2 10) 提供者) 0)
                (list (片段 0 "a" (hash '外观 '粗体)) (片段 1 "中b" #f)))

  ;; 属性不进 外观
  (define b5 (文档-安装-属性 (文档-打开 "abcdef") 只读键 0 3 6 #t))
  (check-equal? (屏幕-屏行 (窗口->屏幕 (窗口-打开 b5 1 10)) 0)
                (list (片段 0 "abcdef" #f)))

  ;; —— 行号栏：片段 前缀 + 光标/选区右移 + 点 边栏 落行首 ——
  (define dln (文档-打开 "a\nb\nc"))
  (define wln2 (窗口-设置-行号 (窗口-打开 dln 3 10) #t))   ; g = 1 位 +1 = 2
  (define sln (窗口->屏幕 wln2))
  (check-equal? (屏幕-屏行 sln 0)
                (list (片段 0 "1 " (hash '外观 '行号)) (片段 2 "a" #f)))
  (check-equal? (屏幕-屏行 sln 2)
                (list (片段 0 "3 " (hash '外观 '行号)) (片段 2 "c" #f)))
  (check-equal? (屏幕-光标-列 sln) 2)                         ; (0,0) → 屏幕列 2
  (check-equal? (call-with-values (lambda () (窗口-屏幕->位置 wln2 0 0)) list) '(0 0))  ; 边栏 → 行首

  ;; 折行：只有 缓冲 行首段显示行号，续段/空行留空
  (define wlnw (窗口-设置-行号 (窗口-设置-模式 (窗口-打开 (文档-打开 "abcdefgh") 3 4) '折行) #t))
  (define sww (窗口->屏幕 wlnw))                               ; g=2 → 正文宽 2
  (check-equal? (屏幕-屏行 sww 0)
                (list (片段 0 "1 " (hash '外观 '行号)) (片段 2 "ab" #f)))
  (check-equal? (屏幕-屏行 sww 1)
                (list (片段 0 "  " (hash '外观 '行号)) (片段 2 "cd" #f)))

  ;; 行号栏让出的宽度影响折行：宽 6、g=2 → 正文宽 4
  (define wln3 (窗口-设置-行号 (窗口-设置-模式 (窗口-打开 (文档-打开 "abcdefgh") 3 6) '折行) #t))
  (check-equal? (窗口-内容-宽度 wln3) 4)
  (check-equal? (map 虚拟行-末尾-列 (vector->list (窗口-虚拟行集 wln3))) '(4 8 8))

  ;; 窄窗 + 多位行号：栏被夹到比数字位数还小也不崩（只保留低位，宽度恰为 g）
  (define 长 (文档-打开 (string-join (for/list ([i (in-range 20)]) (number->string i)) "\n")))
  (define narrow1 (窗口-设置-行号 (窗口-打开 长 3 2) #t))
  (check-equal? (窗口-边栏-宽度 narrow1) 1)
  (check-equal? (片段-文本 (car (屏幕-屏行 (窗口->屏幕 narrow1) 0))) " ")
  (define narrow2 (窗口-设置-行号 (窗口-打开 长 3 3) #t))
  (check-equal? (窗口-边栏-宽度 narrow2) 2)
  (check-equal? (片段-文本 (car (屏幕-屏行 (窗口->屏幕 narrow2) 0))) "1 ")
  (define narrow3 (窗口-设置-行号 (窗口-设置-顶行 (窗口-打开 长 3 3) 9) #t))
  (check-equal? (窗口-边栏-宽度 narrow3) 2)
  (check-equal? (片段-文本 (car (屏幕-屏行 (窗口->屏幕 narrow3) 0))) "0 ")   ; 行号 10 → 只留低位

  (displayln "project.rkt: all tests passed"))
