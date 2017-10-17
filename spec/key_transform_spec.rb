describe JSONAPI::Serializer do
  let(:post) { create(:long_comment) }

  describe 'config.key_transform' do
    context 'default' do
      subject(:serialize) do
        JSONAPI::Serializer.serialize(post, serializer: MyApp::FancyLongCommentSerializer)
      end
      let(:key_transform) { nil }

      it 'applies dash key transformation to type, attribute, links' do
        expect(serialize).to eq(
          'data' => {
            'id' => '1',
            'type' => 'long-comments',
            'attributes' => {
              'id' => 1,
              'fancy-body' => 'Fancy Body for LongComment 1'
            },
            'links' => {
              'self' => '/long-comments/1'
            },
            'relationships' => {
              'user' => {
                'data' => nil
              }
            }
          }
        )
      end
    end

    context 'with specified key_transform' do
      subject(:serialize) do
        with_config(key_transform: key_transform) do
          JSONAPI::Serializer.serialize(post, serializer: MyApp::FancyLongCommentSerializer)
        end
      end

      context 'camel' do
        let(:key_transform) { :camel }

        it 'applies key transformation to type, attribute, links' do
          expect(serialize).to eq(
            'data' => {
              'id' => '1',
              'type' => 'LongComments',
              'attributes' => {
                'Id' => 1,
                'FancyBody' => 'Fancy Body for LongComment 1'
              },
              'links' => {
                'self' => '/LongComments/1'
              },
              'relationships' => {
                'User' => {
                  'data' => nil
                }
              }
            }
          )
        end
      end

      context 'camel_lower' do
        let(:key_transform) { :camel_lower }

        it 'applies key transformation to type, attribute, links' do
          expect(serialize).to eq(
            'data' => {
              'id' => '1',
              'type' => 'longComments',
              'attributes' => {
                'id' => 1,
                'fancyBody' => 'Fancy Body for LongComment 1'
              },
              'links' => {
                'self' => '/longComments/1'
              },
              'relationships' => {
                'user' => {
                  'data' => nil
                }
              }
            }
          )
        end
      end

      context 'dash' do
        let(:key_transform) { :dash }

        it 'applies key transformation to type, attribute, links' do
          expect(serialize).to eq(
            'data' => {
              'id' => '1',
              'type' => 'long-comments',
              'attributes' => {
                'id' => 1,
                'fancy-body' => 'Fancy Body for LongComment 1'
              },
              'links' => {
                'self' => '/long-comments/1'
              },
              'relationships' => {
                'user' => {
                  'data' => nil
                }
              }
            }
          )
        end
      end

      context 'underscore' do
        let(:key_transform) { :underscore }

        it 'applies key transformation to type, attribute, links' do
          expect(serialize).to eq(
            'data' => {
              'id' => '1',
              'type' => 'long_comments',
              'attributes' => {
                'id' => 1,
                'fancy_body' => 'Fancy Body for LongComment 1'
              },
              'links' => {
                'self' => '/long_comments/1'
              },
              'relationships' => {
                'user' => {
                  'data' => nil
                }
              }
            }
          )
        end
      end

      context 'unaltered' do
        let(:key_transform) { :unaltered }

        it 'applies key transformation to type, attribute, links' do
          expect(serialize).to eq(
            'data' => {
              'id' => '1',
              'type' => 'long_comments',
              'attributes' => {
                'id' => 1,
                'fancy_body' => 'Fancy Body for LongComment 1'
              },
              'links' => {
                'self' => '/long_comments/1'
              },
              'relationships' => {
                'user' => {
                  'data' => nil
                }
              }
            }
          )
        end
      end
    end
  end
end
