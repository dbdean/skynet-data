SHELL=/bin/bash

OUTPUT ?= data
QA_TILES ?= planet
DATA_TILES ?= mbtiles://./$(OUTPUT)/osm/$(QA_TILES).mbtiles
BBOX ?= '-180,-85,180,85'
IMAGE_TILES ?= "tilejson+https://a.tiles.mapbox.com/v4/mapbox.satellite.json?access_token=$(MapboxAccessToken)"
TRAIN_SIZE ?= 5000
CLASSES ?= classes/roads.json
LABEL_RATIO ?= 0
ZOOM_LEVEL ?= 17

# Download OSM QA tiles
.PHONY: download-osm-tiles
download-osm-tiles: $(OUTPUT)/osm/$(QA_TILES).mbtiles
	echo "Downloading $(QA_TILES) extract."

$(OUTPUT)/osm/planet.mbtiles:
	mkdir -p $(dir $@)
	curl https://s3.amazonaws.com/mapbox/osm-qa-tiles/latest.planet.mbtiles.gz | gunzip > $@

$(OUTPUT)/osm/%.mbtiles:
	mkdir -p $(dir $@)
	curl https://s3.amazonaws.com/mapbox/osm-qa-tiles/latest.country/$(notdir $@).gz | gunzip > $@


# Make a list of all the tiles within BBOX
$(OUTPUT)/all_tiles.txt:
	if [[ $(DATA_TILES) == mbtiles* ]] ; then \
		tippecanoe-enumerate $(subst mbtiles://./,,$(DATA_TILES)) | node lib/read-sample.js --bbox='$(BBOX)' > $@ ; \
		else echo "$(DATA_TILES) is not an mbtiles source: you will need to create $(OUTPUT)/all_tiles.txt manually." && exit 1 ; \
		fi

# Store the number of desired tiles in a file, so we can update it to reflect missing tiles
$(OUTPUT)/train_size.txt:
	echo ${TRAIN_SIZE} > $@


# Make a random sample from all_tiles.txt of TRAIN_SIZE tiles, possibly
# 'overzooming' them to zoom=ZOOM_LEVEL
$(OUTPUT)/sample.txt: $(OUTPUT)/all_tiles.txt $(OUTPUT)/train_size.txt
	./sample $< $(shell cat $(OUTPUT)/train_size.txt) $(ZOOM_LEVEL) > $@

# Rasterize the data tiles to bitmaps where each pixel is colored according to
# the class defined in CLASSES
# (no class / background => black)
$(OUTPUT)/labels/color: $(OUTPUT)/sample.txt
	mkdir -p $@
	cp $(CLASSES) $(OUTPUT)/classes.json
	cat $(OUTPUT)/sample.txt | \
	  parallel --pipe --block 10K './rasterize-labels $(DATA_TILES) $(CLASSES) $@ $(LABEL_RATIO)'

$(OUTPUT)/labels/label-counts.txt: $(OUTPUT)/labels/color $(OUTPUT)/sample.txt
	#If LABEL_RATIO != 0, this will drop references for images which aren't found
	cat $(OUTPUT)/sample.txt | \
		parallel --pipe --block 10K --group './label-counts $(CLASSES) $(OUTPUT)/labels/color' > $@
	# Also generate label-stats.csv
	cat $(OUTPUT)/labels/label-counts.txt | ./label-stats > $(OUTPUT)/labels/label-stats.csv

# Once we've generated label bitmaps, we can make a version of the original sample
# filtered to tiles with the ratio (pixels with non-background label)/(total pixels)
# above the LABEL_RATIO threshold
$(OUTPUT)/sample-filtered.txt: $(OUTPUT)/labels/label-counts.txt
	cat $^ | node lib/read-sample.js --label-ratio $(LABEL_RATIO) > $@

$(OUTPUT)/labels/grayscale: $(OUTPUT)/sample-filtered.txt
	mkdir -p $@
	cat $^ | \
		cut -d' ' -f2,3,4 | sed 's/ /-/g' | \
		parallel 'cat $(OUTPUT)/labels/color/{}.png | ./palette-to-grayscale $(CLASSES) > $@/{}.png'

$(OUTPUT)/images: $(OUTPUT)/sample-filtered.txt
	mkdir -p $@
	cat $(OUTPUT)/sample-filtered.txt | ./download-images $(IMAGE_TILES) $@

.PHONY: remove-bad-images
remove-bad-images: $(OUTPUT)/sample-filtered.txt
	# Delete satellite images that are too black or too white
	# Afterwards, update the text file so we don't look for these later
	ls $(OUTPUT)/images/* | \
	  ./remove-bad-images

.PHONY: prune-labels
prune-labels: $(OUTPUT)/sample-filtered.txt
	# Iterate through label images, and delete any for which there is no
	# corresponding satellite image
	cat $(OUTPUT)/sample-filtered.txt | \
		cut -d' ' -f2,3,4 | sed 's/ /-/g' > $(OUTPUT)/labels/color/include.txt
	find $(OUTPUT)/labels/color -name *.png | grep -Fvf $(OUTPUT)/labels/color/include.txt | xargs rm
	rm $(OUTPUT)/labels/color/include.txt
	touch $(OUTPUT)/labels/label-counts.txt
	touch $(OUTPUT)/sample-filtered.txt

# Create image pair text files, this will drop references for images which aren't found
$(OUTPUT)/image-pairs.txt: $(OUTPUT)/sample-filtered.txt $(OUTPUT)/labels/grayscale $(OUTPUT)/images
	cat $(OUTPUT)/sample-filtered.txt | \
		./list-image-pairs --basedir $$(cd $(OUTPUT) && pwd -P) \
			--labels labels/grayscale \
			--images images > $@

# Make train & val lists, with 80% of data -> train, 20% -> val
$(OUTPUT)/train.txt: $(OUTPUT)/image-pairs.txt
	shuf $(OUTPUT)/image-pairs.txt > $(OUTPUT)/temp.txt
	split -l $$(($$(cat $(OUTPUT)/image-pairs.txt | wc -l) * 4 / 5)) $(OUTPUT)/temp.txt $(OUTPUT)/x
	rm $(OUTPUT)/temp.txt
	mv $(OUTPUT)/xaa $@
	mv $(OUTPUT)/xab $(OUTPUT)/val.txt

.PHONY: all
all: $(OUTPUT)/train.txt $(OUTPUT)/val.txt

.PHONY: clean-labels clean-images clean
clean-labels:
	rm -rf $(OUTPUT)/labels
clean-images:
	rm -rf $(OUTPUT)/images
clean: clean-images clean-labels
	rm $(OUTPUT)/sample.txt
